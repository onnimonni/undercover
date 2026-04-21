defmodule Mix.Tasks.ExUndercover.VerifySolverAlignment do
  use Mix.Task

  @shortdoc "Compare fast-path fingerprint with real Chrome solver fingerprint"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [
          profile: :string,
          browser_path: :string,
          solve_wait_ms: :integer
        ]
      )

    profile_id = String.to_atom(opts[:profile] || "chrome_latest")

    with {:ok, profile} <- resolve_profile(profile_id),
         {:ok, browser} <-
           ExUndercover.Solver.Chrome.browser_info(browser_path: opts[:browser_path]),
         :ok <- verify_major_alignment(profile, browser),
         {:ok, fast_payload} <- fast_report(profile_id),
         {:ok, solver_payload} <- solver_report(profile_id, opts),
         :ok <- compare_payloads(fast_payload, solver_payload) do
      Mix.shell().info("""
      solver alignment passed
      browser=#{browser.version}
      ja4=#{get_in(fast_payload, ["tls", "ja4"])}
      akamai_hash=#{get_in(fast_payload, ["http2", "akamai_fingerprint_hash"])}
      """)
    else
      {:error, reason} ->
        Mix.raise("solver alignment failed: #{inspect(reason, pretty: true)}")
    end
  end

  defp resolve_profile(profile_id) do
    {:ok, ExUndercover.Profile.resolve(profile_id)}
  rescue
    error -> {:error, {:profile_resolve_failed, Exception.message(error)}}
  end

  defp verify_major_alignment(profile, browser) do
    profile_major =
      profile.id
      |> Atom.to_string()
      |> String.split("_")
      |> List.last()
      |> String.to_integer()

    if profile_major == browser.major do
      :ok
    else
      {:error,
       {:browser_profile_major_mismatch,
        %{
          profile_major: profile_major,
          browser_major: browser.major,
          browser_version: browser.version
        }}}
    end
  end

  defp fast_report(profile_id) do
    request =
      ExUndercover.Request.new("https://tls.peet.ws/api/all", browser_profile: profile_id)

    with {:ok, response} <- ExUndercover.request(request, solver: false),
         {:ok, payload} <- Jason.decode(response.body) do
      {:ok, payload}
    end
  end

  defp solver_report(profile_id, opts) do
    solver_opts =
      []
      |> put_opt(:browser_profile, profile_id)
      |> put_opt(:browser_path, opts[:browser_path])
      |> put_opt(:solve_wait_ms, opts[:solve_wait_ms] || 4_000)

    with {:ok, result} <-
           ExUndercover.Solver.Chrome.solve("https://tls.peet.ws/api/all", solver_opts),
         body when is_binary(body) <- result[:body_text],
         {:ok, payload} <- Jason.decode(body) do
      {:ok, payload}
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :solver_body_missing}
      other -> {:error, {:solver_unexpected_body, other}}
    end
  end

  defp compare_payloads(fast_payload, solver_payload) do
    comparisons = [
      {:ja4, get_in(fast_payload, ["tls", "ja4"]), get_in(solver_payload, ["tls", "ja4"])},
      {:akamai_hash, get_in(fast_payload, ["http2", "akamai_fingerprint_hash"]),
       get_in(solver_payload, ["http2", "akamai_fingerprint_hash"])},
      {:http_version, fast_payload["http_version"], solver_payload["http_version"]},
      {:user_agent, fast_payload["user_agent"], solver_payload["user_agent"]},
      {:header_order, header_order(fast_payload), header_order(solver_payload)}
    ]

    case Enum.find(comparisons, fn {_name, left, right} -> left != right end) do
      nil ->
        :ok

      {name, left, right} ->
        {:error, {:payload_mismatch, %{field: name, fast: left, solver: right}}}
    end
  end

  defp header_order(payload) do
    payload
    |> get_in(["http2", "sent_frames"])
    |> Enum.find_value([], &headers_frame/1)
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp headers_frame(%{"frame_type" => "HEADERS", "headers" => headers}) do
    Enum.map(headers, &header_name/1)
  end

  defp headers_frame(_frame), do: false

  defp header_name(header) do
    case String.split(header, ": ", parts: 2) do
      [name, _] -> name
      [name] -> name
    end
  end
end
