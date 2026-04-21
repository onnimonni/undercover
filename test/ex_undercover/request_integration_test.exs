defmodule ExUndercover.RequestIntegrationTest do
  use ExUnit.Case, async: false

  alias ExUndercover.Request
  alias ExUndercover.Rotator
  alias ExUndercover.Solver.Registry
  alias ExUndercover.TestSupport.CountingSolver
  alias ExUndercover.TestSupport.HTTPServer
  alias ExUndercover.TestSupport.TestSolver

  setup do
    :ok = ExUndercover.clear_cookies()
    start_supervised!({Rotator, name: :test_rotator, host_debounce_ms: 10})
    :ok
  end

  test "executes a plain http request through the native transport" do
    port =
      start_server(fn _request ->
        %{
          status: 200,
          headers: [{"content-type", "text/plain"}],
          body: "plain-http-ok"
        }
      end)

    assert {:ok, response} =
             HTTPServer.url(port)
             |> Request.new(browser_profile: :chrome_latest)
             |> ExUndercover.request(solver: false)

    assert response.status == 200
    assert response.body == "plain-http-ok"
    assert response.browser_profile == :chrome_147
    assert response.diagnostics["transport"] == "wreq_boringssl"
    assert response.diagnostics["profile_id"] == "chrome_147"
  end

  test "accepts url binaries through the public api" do
    port =
      start_server(fn request ->
        %{status: 200, body: Map.get(request.headers, "x-test", "missing")}
      end)

    assert {:ok, response} =
             ExUndercover.request(
               HTTPServer.url(port),
               headers: [{"x-test", "value-from-url-overload"}],
               solver: false
             )

    assert response.status == 200
    assert response.body == "value-from-url-overload"
  end

  test "follows redirects and carries cookies automatically" do
    port =
      start_server(fn request ->
        case {request.target, Map.get(request.headers, "cookie", "")} do
          {"/start", _cookie} ->
            %{
              status: 302,
              headers: [
                {"location", "/final"},
                {"set-cookie", "sid=redirected; Path=/; HttpOnly"}
              ]
            }

          {"/final", cookie} ->
            if String.contains?(cookie, "sid=redirected") do
              %{status: 200, body: "redirect-ok"}
            else
              %{status: 403, body: "missing-cookie"}
            end
        end
      end)

    assert {:ok, response} =
             ExUndercover.request(
               HTTPServer.url(port, "/start"),
               solver: false,
               metadata: %{"wireguard_ip_address" => "10.0.0.2"}
             )

    assert response.status == 200
    assert response.body == "redirect-ok"
    assert response.diagnostics["redirect_count"] == 1
    assert response.diagnostics["final_url"] == HTTPServer.url(port, "/final")
    assert response.diagnostics["cookie_jar_bucket"] == "10.0.0.2"
  end

  test "can disable redirect following while still storing redirect cookies" do
    port =
      start_server(fn request ->
        case {request.target, Map.get(request.headers, "cookie", "")} do
          {"/start", _cookie} ->
            %{
              status: 302,
              headers: [{"location", "/final"}, {"set-cookie", "sid=kept; Path=/"}],
              body: "redirect"
            }

          {"/final", cookie} ->
            if String.contains?(cookie, "sid=kept") do
              %{status: 200, body: "cookie-kept"}
            else
              %{status: 403, body: "missing-cookie"}
            end
        end
      end)

    bucket = %{"wireguard_ip_address" => "10.0.0.2"}

    assert {:ok, response} =
             ExUndercover.request(HTTPServer.url(port, "/start"),
               solver: false,
               follow_redirects: false,
               metadata: bucket
             )

    assert response.status == 302
    assert response.diagnostics["redirect_count"] == 0

    assert {:ok, %{status: 200, body: "cookie-kept"}} =
             ExUndercover.request(HTTPServer.url(port, "/final"),
               solver: false,
               metadata: bucket
             )
  end

  test "rewrites post to get on 302 redirects" do
    port =
      start_server(fn request ->
        case request.target do
          "/submit" ->
            %{status: 302, headers: [{"location", "/landing"}], body: "redirecting"}

          "/landing" ->
            %{status: 200, body: "#{request.method}:#{request.body}"}
        end
      end)

    assert {:ok, response} =
             HTTPServer.url(port, "/submit")
             |> Request.new(method: :post, body: "posted", browser_profile: :chrome_latest)
             |> ExUndercover.request(solver: false)

    assert response.status == 200
    assert response.body == "GET:"
    assert response.diagnostics["redirect_count"] == 1
  end

  test "preserves method and body on 307 redirects" do
    port =
      start_server(fn request ->
        case request.target do
          "/submit" ->
            %{status: 307, headers: [{"location", "/landing"}], body: "redirecting"}

          "/landing" ->
            %{
              status: 200,
              body:
                "#{request.method}:#{request.body}:#{Map.get(request.headers, "content-type")}"
            }
        end
      end)

    assert {:ok, response} =
             HTTPServer.url(port, "/submit")
             |> Request.new(
               method: :post,
               headers: [{"content-type", "text/plain"}],
               body: "posted",
               browser_profile: :chrome_latest
             )
             |> ExUndercover.request(solver: false)

    assert response.status == 200
    assert response.body == "POST:posted:text/plain"
    assert response.diagnostics["redirect_count"] == 1
  end

  test "encodes request bodies and headers for native requests" do
    port =
      start_server(fn request ->
        %{
          status: 200,
          body: "#{request.method}:#{request.body}:#{Map.get(request.headers, "content-type")}"
        }
      end)

    assert {:ok, response} =
             HTTPServer.url(port)
             |> Request.new(
               method: :post,
               headers: [{"content-type", "text/plain"}],
               body: ["o", "k"],
               browser_profile: :chrome_latest
             )
             |> ExUndercover.request(solver: false)

    assert response.status == 200
    assert response.body == "POST:ok:text/plain"
  end

  test "escalates challenge responses through the solver boundary and retries" do
    port = start_server(&challenge_response/1)

    assert {:ok, response} =
             HTTPServer.url(port)
             |> Request.new(browser_profile: :chrome_latest)
             |> ExUndercover.request(
               solver: true,
               solver_backend: TestSolver,
               rotator: :test_rotator
             )

    assert response.status == 200
    assert response.body == "solver-ok"
    assert response.diagnostics["classification"] == :challenge_solved
    assert %{browser: :chrome} = response.diagnostics["solver"]

    assert [%{classification: :challenge, host: "127.0.0.1"} | _rest] =
             Rotator.recent(:test_rotator)
  end

  test "deduplicates concurrent challenge solves for the same host and wireguard bucket" do
    port = start_server(&challenge_response/1)
    test_pid = self()

    start_supervised!(
      {Registry,
       name: :burst_solver_registry, max_concurrency: 1, max_queue: 10, circuit_threshold: 2}
    )

    request =
      Request.new(HTTPServer.url(port),
        browser_profile: :chrome_latest,
        metadata: %{"wireguard_ip_address" => "10.0.0.2"}
      )

    tasks =
      for _ <- 1..5 do
        Task.async(fn ->
          ExUndercover.request(request,
            solver: true,
            solver_backend: CountingSolver,
            solver_registry: :burst_solver_registry,
            notify_pid: test_pid,
            solver_delay_ms: 150
          )
        end)
      end

    assert_receive {:solver_called, _, _}, 1_000
    refute_receive {:solver_called, _, _}, 100

    responses = Enum.map(tasks, &Task.await(&1, 2_000))

    assert Enum.all?(responses, fn
             {:ok,
              %{
                status: 200,
                body: "solver-ok",
                diagnostics: %{"classification" => :challenge_solved}
              }} ->
               true

             _other ->
               false
           end)
  end

  test "marks challenge responses as unsolved when the solver fails" do
    port = start_server(&challenge_response/1)

    assert {:ok, response} =
             HTTPServer.url(port)
             |> Request.new(browser_profile: :chrome_latest)
             |> ExUndercover.request(
               solver: true,
               solver_backend: ExUndercover.RequestIntegrationTest.FailingSolver,
               rotator: :test_rotator
             )

    assert response.status == 403
    assert response.diagnostics["classification"] == :challenge_unsolved
    assert response.diagnostics["solver_error"] == ":solver_failed"
  end

  test "opens the solver circuit after repeated challenged retries and skips further launches" do
    port = start_server(&challenge_response/1)

    start_supervised!(
      {Registry,
       name: :circuit_solver_registry,
       max_concurrency: 1,
       max_queue: 10,
       circuit_threshold: 2,
       circuit_open_ms: 5_000}
    )

    solver_opts = [
      solver: true,
      solver_backend: CountingSolver,
      solver_registry: :circuit_solver_registry,
      notify_pid: self(),
      solver_result:
        {:ok,
         %{
           browser: :chrome,
           cookies: [%{name: "solver", value: "bad"}],
           current_url: "http://solver.local/fail",
           title: "Blocked",
           body_text: "bad",
           headless: true
         }}
    ]

    assert {:ok, first_response} =
             ExUndercover.request(HTTPServer.url(port), solver_opts)

    assert first_response.status == 403
    assert first_response.diagnostics["classification"] == :challenge_unsolved
    assert_receive {:solver_called, _, _}, 1_000

    assert {:ok, second_response} =
             ExUndercover.request(HTTPServer.url(port), solver_opts)

    assert second_response.status == 403
    assert second_response.diagnostics["classification"] == :challenge_circuit_open
    assert_receive {:solver_called, _, _}, 1_000

    assert {:ok, third_response} =
             ExUndercover.request(HTTPServer.url(port), solver_opts)

    assert third_response.status == 403
    assert third_response.diagnostics["classification"] == :challenge_circuit_open
    refute_receive {:solver_called, _, _}, 100
  end

  test "marks solver overload when the browser queue is saturated" do
    port = start_server(&challenge_response/1)
    test_pid = self()

    start_supervised!(
      {Registry,
       name: :overloaded_solver_registry, max_concurrency: 1, max_queue: 0, circuit_threshold: 2}
    )

    running_task =
      Task.async(fn ->
        ExUndercover.request(HTTPServer.url(port),
          solver: true,
          solver_backend: CountingSolver,
          solver_registry: :overloaded_solver_registry,
          notify_pid: test_pid,
          solver_delay_ms: 250
        )
      end)

    assert_receive {:solver_called, _, _}, 1_000

    overloaded_url =
      String.replace_prefix(HTTPServer.url(port), "http://127.0.0.1", "http://localhost")

    assert {:ok, overloaded_response} =
             ExUndercover.request(overloaded_url,
               solver: true,
               solver_backend: CountingSolver,
               solver_registry: :overloaded_solver_registry,
               notify_pid: test_pid
             )

    assert overloaded_response.status == 403
    assert overloaded_response.diagnostics["classification"] == :challenge_solver_overloaded
    assert {:ok, %{status: 200}} = Task.await(running_task, 2_000)
  end

  test "marks responses when solver escalation is disabled" do
    port = start_server(fn _request -> %{status: 200, body: "ok"} end)

    assert {:ok, response} =
             HTTPServer.url(port)
             |> Request.new(browser_profile: :chrome_latest)
             |> ExUndercover.request(solver: false)

    assert response.status == 200
    assert response.diagnostics["classification"] == :solver_disabled
  end

  test "notifies the rotator for rate limited responses" do
    port = start_server(fn _request -> %{status: 429, body: "slow down"} end)

    assert {:ok, response} =
             HTTPServer.url(port)
             |> Request.new(browser_profile: :chrome_latest)
             |> ExUndercover.request(solver: true, rotator: :test_rotator)

    assert response.status == 429
    assert response.diagnostics["classification"] == :rate_limited

    assert [%{classification: :rate_limited, host: "127.0.0.1"} | _rest] =
             Rotator.recent(:test_rotator)
  end

  test "classifies plain access denials without escalation" do
    port = start_server(fn _request -> %{status: 403, body: "denied"} end)

    assert {:ok, response} =
             HTTPServer.url(port)
             |> Request.new(browser_profile: :chrome_latest)
             |> ExUndercover.request(solver: true, rotator: :test_rotator)

    assert response.status == 403
    assert response.diagnostics["classification"] == :access_denied
  end

  test "shares cookies for the same wireguard bucket and keeps them isolated across buckets" do
    port =
      start_server(fn request ->
        case {request.target, Map.get(request.headers, "cookie", "")} do
          {"/set", _cookie} ->
            %{status: 200, headers: [{"set-cookie", "shared=1; Path=/"}], body: "set"}

          {"/use", cookie} ->
            if String.contains?(cookie, "shared=1") do
              %{status: 200, body: "shared-ok"}
            else
              %{status: 403, body: "missing-shared-cookie"}
            end
        end
      end)

    bucket_a = %{"wireguard_ip_address" => "10.0.0.2"}
    bucket_b = %{"wireguard_ip_address" => "10.0.0.3"}

    assert {:ok, %{status: 200}} =
             ExUndercover.request(HTTPServer.url(port, "/set"),
               solver: false,
               metadata: bucket_a
             )

    assert {:ok, %{status: 200, body: "shared-ok"}} =
             ExUndercover.request(HTTPServer.url(port, "/use"),
               solver: false,
               metadata: bucket_a
             )

    assert {:ok, %{status: 403, body: "missing-shared-cookie"}} =
             ExUndercover.request(HTTPServer.url(port, "/use"),
               solver: false,
               metadata: bucket_b
             )

    assert :ok = ExUndercover.clear_cookies(wireguard_ip_address: "10.0.0.2")

    assert {:ok, %{status: 403, body: "missing-shared-cookie"}} =
             ExUndercover.request(HTTPServer.url(port, "/use"),
               solver: false,
               metadata: bucket_a
             )
  end

  test "can clear cookies by request scope even when the wireguard bucket stays the same" do
    port =
      start_server(fn request ->
        case {request.target, Map.get(request.headers, "cookie", "")} do
          {"/set", _cookie} ->
            %{status: 200, headers: [{"set-cookie", "scoped=1; Path=/"}], body: "set"}

          {"/use", cookie} ->
            if String.contains?(cookie, "scoped=1") do
              %{status: 200, body: "scoped-ok"}
            else
              %{status: 403, body: "missing-scoped-cookie"}
            end
        end
      end)

    request =
      Request.new(HTTPServer.url(port, "/use"),
        browser_profile: :chrome_latest,
        metadata: %{"wireguard_ip_address" => "10.0.0.2"}
      )

    assert {:ok, %{status: 200}} =
             ExUndercover.request(HTTPServer.url(port, "/set"),
               solver: false,
               metadata: %{"wireguard_ip_address" => "10.0.0.2"}
             )

    assert {:ok, %{status: 200, body: "scoped-ok"}} =
             ExUndercover.request(request, solver: false)

    assert :ok = ExUndercover.clear_cookies(request)

    assert {:ok, %{status: 403, body: "missing-scoped-cookie"}} =
             ExUndercover.request(request, solver: false)
  end

  test "returns an error when redirects exceed the configured limit" do
    port =
      start_server(fn request ->
        %{status: 302, headers: [{"location", request.target}], body: "loop"}
      end)

    assert {:error, :too_many_redirects} =
             ExUndercover.request(HTTPServer.url(port, "/loop"),
               solver: false,
               max_redirects: 0
             )
  end

  defp start_server(handler) do
    {:ok, pid} = HTTPServer.start_link(handler)

    receive do
      {:http_server_ready, ^pid, listen_socket, port} ->
        on_exit(fn ->
          :gen_tcp.close(listen_socket)
          Process.exit(pid, :kill)
        end)

        port
    after
      2_000 ->
        flunk("http test server failed to start")
    end
  end

  defp challenge_response(request) do
    case Map.get(request.headers, "cookie", "") do
      cookie when is_binary(cookie) ->
        if String.contains?(cookie, "solver=ok") do
          %{status: 200, body: "solver-ok"}
        else
          %{
            status: 403,
            headers: [{"cf-mitigated", "challenge"}, {"server", "cloudflare"}],
            body: "challenge"
          }
        end

      _other ->
        %{
          status: 403,
          headers: [{"cf-mitigated", "challenge"}, {"server", "cloudflare"}],
          body: "challenge"
        }
    end
  end
end

defmodule ExUndercover.RequestIntegrationTest.FailingSolver do
  @behaviour ExUndercover.Solver

  @impl true
  def solve(_url, _opts), do: {:error, :solver_failed}
end
