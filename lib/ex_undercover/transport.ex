defmodule ExUndercover.Transport do
  @moduledoc """
  Main request orchestration.
  """

  alias ExUndercover.AntiBot
  alias ExUndercover.Client
  alias ExUndercover.CookieJar
  alias ExUndercover.Request
  alias ExUndercover.Response
  alias ExUndercover.Rotator

  @type outcome :: {:ok, Response.t()} | {:error, term()}
  @default_max_redirects 10

  @spec request(Request.t(), keyword()) :: outcome()
  def request(%Request{} = request, opts \\ []) do
    solver_backend = Keyword.get(opts, :solver_backend, ExUndercover.Solver.Chrome)
    solver_registry = Keyword.get(opts, :solver_registry, ExUndercover.Solver.Registry)
    solver_enabled? = Keyword.get(opts, :solver, true)
    rotator = Keyword.get(opts, :rotator, ExUndercover.Rotator)

    with {:ok, response, effective_request} <- execute_request(request, opts),
         {:ok, response} <-
           maybe_escalate(
             response,
             effective_request,
             solver_enabled?,
             solver_backend,
             solver_registry,
             rotator,
             opts
           ) do
      {:ok, response}
    end
  end

  defp maybe_escalate(
         %Response{} = response,
         request,
         true,
         solver_backend,
         solver_registry,
         rotator,
         opts
       ) do
    case AntiBot.classify(response) do
      {:challenge, details} ->
        notify_rotator(rotator, request.url, :challenge, details)

        solve_and_retry(
          response,
          request,
          solver_backend,
          solver_registry,
          details,
          rotator,
          opts
        )

      {classification, details} ->
        maybe_notify_rotation_signal(rotator, request.url, classification, details)
        {:ok, merge_diagnostics(response, %{classification: classification, details: details})}
    end
  end

  defp maybe_escalate(
         %Response{} = response,
         _request,
         false,
         _backend,
         _solver_registry,
         _rotator,
         _opts
       ) do
    {:ok, merge_diagnostics(response, %{classification: :solver_disabled})}
  end

  defp solve_and_retry(response, request, solver_backend, solver_registry, details, rotator, opts) do
    cookie_jar = Keyword.get(opts, :cookie_jar, ExUndercover.CookieJar)

    solver_opts =
      opts
      |> Keyword.put(:backend, solver_backend)
      |> Keyword.put(:browser_profile, request.browser_profile)

    if ExUndercover.Solver.Registry.circuit_open?(solver_registry, request, solver_opts) do
      {:ok,
       merge_diagnostics(response, %{
         classification: :challenge_circuit_open,
         challenge: details,
         solver_error: "solver circuit open"
       })}
    else
      with {:ok, solve_result} <-
             ExUndercover.Solver.Registry.lookup_or_solve(solver_registry, request, solver_opts),
           :ok <- store_solver_cookies(cookie_jar, request, solve_result),
           retried_request <- attach_solver_artifacts(request, solve_result),
           {:ok, retried_response, _effective_request} <-
             execute_request(retried_request, Keyword.put(opts, :solver, false)) do
        handle_solver_retry_result(
          retried_response,
          response,
          request,
          solve_result,
          solver_registry,
          rotator,
          cookie_jar,
          details,
          solver_opts
        )
      else
        {:error, reason} ->
          {:ok,
           merge_diagnostics(response, %{
             classification: classify_solver_error(reason),
             challenge: details,
             solver_error: inspect(reason)
           })}
      end
    end
  end

  defp handle_solver_retry_result(
         %Response{} = retried_response,
         %Response{} = initial_response,
         %Request{} = request,
         solve_result,
         solver_registry,
         rotator,
         cookie_jar,
         challenge_details,
         solver_opts
       ) do
    case AntiBot.classify(retried_response) do
      {:ok, details} ->
        :ok =
          ExUndercover.Solver.Registry.mark_retry_succeeded(
            solver_registry,
            request,
            solver_opts
          )

        {:ok,
         merge_diagnostics(retried_response, %{
           classification: :challenge_solved,
           initial_response: summarize_response(initial_response),
           challenge: challenge_details,
           retry_details: details,
           solver: solve_result
         })}

      {:challenge, retry_details} ->
        circuit =
          ExUndercover.Solver.Registry.mark_retry_failed(solver_registry, request, solver_opts)

        :ok = CookieJar.clear(cookie_jar, request: request)

        {:ok,
         merge_diagnostics(retried_response, %{
           classification:
             if(circuit.open?, do: :challenge_circuit_open, else: :challenge_unsolved),
           initial_response: summarize_response(initial_response),
           challenge: challenge_details,
           retry_classification: :challenge,
           retry_details: retry_details,
           solver: solve_result,
           solver_circuit: circuit
         })}

      {classification, retry_details} ->
        maybe_notify_rotation_signal(rotator, request.url, classification, retry_details)

        {:ok,
         merge_diagnostics(retried_response, %{
           classification: :challenge_unsolved,
           initial_response: summarize_response(initial_response),
           challenge: challenge_details,
           retry_classification: classification,
           retry_details: retry_details,
           solver: solve_result
         })}
    end
  end

  defp attach_solver_artifacts(%Request{} = request, solve_result) do
    metadata_patch =
      solve_result
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("solver_retry", true)

    %Request{
      request
      | headers: strip_cookie_headers(request.headers),
        metadata: Map.merge(request.metadata, metadata_patch)
    }
  end

  defp strip_cookie_headers(headers) do
    Enum.reject(headers, fn
      {k, _v} -> String.downcase(k) == "cookie"
      [k, _v] -> String.downcase(k) == "cookie"
    end)
  end

  defp execute_request(%Request{} = request, opts) do
    cookie_jar = Keyword.get(opts, :cookie_jar, ExUndercover.CookieJar)
    follow_redirects? = Keyword.get(opts, :follow_redirects, true)
    max_redirects = Keyword.get(opts, :max_redirects, @default_max_redirects)
    client_opts = client_opts(opts)

    do_execute_request(request, client_opts, cookie_jar, follow_redirects?, max_redirects, [])
  end

  defp do_execute_request(
         %Request{} = request,
         client_opts,
         cookie_jar,
         follow_redirects?,
         remaining_redirects,
         redirect_chain
       ) do
    :ok = CookieJar.seed_request_cookies(cookie_jar, request)
    request = apply_cookie_jar(request, cookie_jar)

    with {:ok, response} <- Client.request(request, client_opts),
         :ok <- CookieJar.store_response(cookie_jar, request, response.headers) do
      maybe_follow_redirect(
        response,
        request,
        client_opts,
        cookie_jar,
        follow_redirects?,
        remaining_redirects,
        redirect_chain
      )
    end
  end

  defp maybe_follow_redirect(
         %Response{} = response,
         %Request{} = request,
         client_opts,
         cookie_jar,
         true,
         remaining_redirects,
         redirect_chain
       ) do
    case redirect_location(response) do
      nil ->
        {:ok, decorate_response(response, request, redirect_chain), request}

      location when remaining_redirects > 0 ->
        next_request = redirect_request(request, response, location)

        do_execute_request(
          next_request,
          client_opts,
          cookie_jar,
          true,
          remaining_redirects - 1,
          redirect_chain ++ [redirect_entry(request.url, response.status, location)]
        )

      _location ->
        {:error, :too_many_redirects}
    end
  end

  defp maybe_follow_redirect(
         %Response{} = response,
         %Request{} = request,
         _client_opts,
         _cookie_jar,
         false,
         _remaining_redirects,
         redirect_chain
       ) do
    {:ok, decorate_response(response, request, redirect_chain), request}
  end

  defp redirect_location(%Response{status: status, headers: headers})
       when status in [301, 302, 303, 307, 308] do
    headers
    |> Enum.find_value(fn
      {name, value} when is_binary(name) ->
        if String.downcase(name) == "location", do: value

      [name, value] when is_binary(name) ->
        if String.downcase(name) == "location", do: value

      _other ->
        nil
    end)
  end

  defp redirect_location(_response), do: nil

  defp redirect_request(%Request{} = request, %Response{status: status}, location) do
    method = redirect_method(status, request.method)
    preserve_body? = method == request.method and status in [307, 308]

    %Request{
      request
      | url: URI.merge(request.url, location) |> to_string(),
        method: method,
        body: if(preserve_body?, do: request.body, else: nil),
        headers: redirect_headers(request.headers, preserve_body?)
    }
  end

  defp redirect_method(303, :head), do: :head
  defp redirect_method(303, _method), do: :get

  defp redirect_method(status, method) when status in [301, 302] and method in [:get, :head],
    do: method

  defp redirect_method(status, _method) when status in [301, 302], do: :get
  defp redirect_method(_status, method), do: method

  defp redirect_headers(headers, preserve_body?) do
    reject =
      if preserve_body? do
        ["cookie", "content-length", "host"]
      else
        ["cookie", "content-length", "content-type", "host", "transfer-encoding"]
      end

    Enum.reject(headers, fn
      {name, _value} ->
        String.downcase(name) in reject

      [name, _value] ->
        String.downcase(name) in reject
    end)
  end

  defp apply_cookie_jar(%Request{} = request, cookie_jar) do
    case CookieJar.cookie_header(cookie_jar, request) do
      nil ->
        %Request{request | headers: strip_cookie_headers(request.headers)}

      cookie_header ->
        %Request{
          request
          | headers: [{"cookie", cookie_header} | strip_cookie_headers(request.headers)]
        }
    end
  end

  defp decorate_response(%Response{} = response, %Request{} = request, redirect_chain) do
    merge_diagnostics(response, %{
      redirect_count: length(redirect_chain),
      redirect_chain: redirect_chain,
      final_url: request.url,
      cookie_jar_bucket: CookieJar.bucket_for(request)
    })
  end

  defp redirect_entry(from, status, location) do
    %{"from" => from, "status" => status, "location" => location}
  end

  defp client_opts(_opts), do: []

  defp store_solver_cookies(cookie_jar, %Request{} = request, solve_result) do
    cookies = Map.get(solve_result, :cookies, Map.get(solve_result, "cookies", []))
    CookieJar.store_cookies(cookie_jar, request, cookies)
  end

  defp summarize_response(%Response{} = response) do
    %{
      status: response.status,
      remote_address: response.remote_address
    }
  end

  defp merge_diagnostics(%Response{} = response, extra) do
    %Response{response | diagnostics: Map.merge(response.diagnostics, stringify_map(extra))}
  end

  defp classify_solver_error({:solver_circuit_open, _details}), do: :challenge_circuit_open
  defp classify_solver_error(:solver_queue_full), do: :challenge_solver_overloaded
  defp classify_solver_error(_reason), do: :challenge_unsolved

  defp stringify_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp maybe_notify_rotation_signal(rotator, url, classification, details)
       when classification in [:rate_limited, :challenge] do
    notify_rotator(rotator, url, classification, details)
  end

  defp maybe_notify_rotation_signal(_rotator, _url, _classification, _details), do: :ok

  defp notify_rotator(rotator, url, classification, details) do
    host =
      case URI.parse(url) do
        %URI{host: host} when is_binary(host) -> host
        _ -> "unknown"
      end

    Rotator.notify(rotator, host, classification, details)
  end
end
