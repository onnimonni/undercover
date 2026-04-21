defmodule ExUndercover.Solver.Chrome do
  @behaviour ExUndercover.Solver

  alias ExUndercover.Profile
  alias ExUndercover.Solver.Chrome.CDPConnection

  @default_boot_timeout_ms 15_000
  @default_solve_wait_ms 8_000
  @browser_candidates [
    "google-chrome",
    "google-chrome-stable",
    "chromium",
    "chromium-browser",
    "chrome",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium"
  ]

  @impl true
  def solve(url, opts) do
    with {:ok, browser} <- browser_info(opts),
         {:ok, port} <- free_tcp_port(),
         {:ok, session} <- launch_session(browser.path, port, url, opts),
         {:ok, result} <- run_session(session, url, opts) do
      {:ok,
       result
       |> Map.put(:browser_path, browser.path)
       |> Map.put(:browser_version, browser.version)
       |> Map.put(:browser_major, browser.major)}
    end
  end

  @spec browser_info(keyword()) ::
          {:ok, %{path: binary(), version: binary(), major: pos_integer()}} | {:error, term()}
  def browser_info(opts \\ []) do
    with {:ok, path} <- browser_path(opts),
         {:ok, version} <- browser_version(path),
         {:ok, major} <- browser_major(version) do
      {:ok, %{path: path, version: version, major: major}}
    end
  end

  defp run_session(session, url, opts) do
    try do
      with :ok <- wait_for_devtools(session.port, opts),
           {:ok, target} <- create_target(session.port, url),
           {:ok, socket} <- CDPConnection.start_link(target["webSocketDebuggerUrl"], self()),
           {:ok, _page_enabled} <- cdp_command(socket, "Page.enable"),
           {:ok, _network_enabled} <- cdp_command(socket, "Network.enable"),
           :ok <- wait_for_solver_window(opts),
           {:ok, cookies} <- cdp_command(socket, "Network.getAllCookies"),
           {:ok, current_url} <- evaluate(socket, "window.location.href"),
           {:ok, title} <- evaluate(socket, "document.title"),
           {:ok, body_text} <- page_text(socket) do
        {:ok,
         %{
           browser: :chrome,
           cookies: normalize_cookies(cookies["cookies"]),
           current_url: current_url,
           title: title,
           body_text: body_text,
           headless: Keyword.get(opts, :headless, true)
         }}
      end
    after
      cleanup_session(session)
    end
  end

  defp launch_session(browser_path, port, _url, opts) do
    profile = solver_profile(opts)
    user_data_dir = user_data_dir(opts)
    File.mkdir_p!(user_data_dir)

    args =
      chrome_args(port, user_data_dir, profile, opts) ++
        Keyword.get(opts, :chrome_args, ["about:blank"])

    port_ref =
      Port.open({:spawn_executable, browser_path}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :use_stdio,
        :hide,
        args: args
      ])

    {:ok,
     %{
       browser_path: browser_path,
       port: port,
       port_ref: port_ref,
       os_pid: Keyword.get(Port.info(port_ref), :os_pid),
       user_data_dir: user_data_dir
     }}
  rescue
    error -> {:error, {:launch_failed, Exception.message(error)}}
  end

  defp chrome_args(port, user_data_dir, profile, opts) do
    headless =
      if Keyword.get(opts, :headless, true) do
        ["--headless=new"]
      else
        []
      end

    headless ++
      [
        "--remote-debugging-port=#{port}",
        "--remote-debugging-address=127.0.0.1",
        "--user-data-dir=#{user_data_dir}",
        "--disable-gpu",
        "--disable-dev-shm-usage",
        "--no-first-run",
        "--no-default-browser-check",
        "--no-sandbox",
        "--disable-background-networking",
        "--disable-sync",
        "--disable-features=MediaRouter,OptimizationHints,AutofillServerCommunication",
        "--disable-blink-features=AutomationControlled",
        "--window-size=#{Keyword.get(opts, :window_size, "1280,900")}",
        "--user-agent=#{solver_user_agent(profile)}"
      ]
  end

  defp solver_profile(opts) do
    opts
    |> Keyword.get(:browser_profile, :chrome_latest)
    |> Profile.resolve()
  end

  defp solver_user_agent(profile) do
    profile.headers
    |> Enum.find_value(fn
      {"user-agent", value} -> value
      _header -> nil
    end)
  end

  defp wait_for_solver_window(opts) do
    Process.sleep(Keyword.get(opts, :solve_wait_ms, @default_solve_wait_ms))
    :ok
  end

  defp wait_for_devtools(port, opts) do
    start_httpc()

    deadline =
      System.monotonic_time(:millisecond) +
        Keyword.get(opts, :boot_timeout_ms, @default_boot_timeout_ms)

    do_wait_for_devtools(port, deadline)
  end

  defp do_wait_for_devtools(port, deadline_ms) do
    if System.monotonic_time(:millisecond) > deadline_ms do
      {:error, :devtools_timeout}
    else
      case http_get_json("http://127.0.0.1:#{port}/json/version") do
        {:ok, _json} ->
          :ok

        {:error, _reason} ->
          Process.sleep(200)
          do_wait_for_devtools(port, deadline_ms)
      end
    end
  end

  defp create_target(port, url) do
    encoded_url = URI.encode(url, &URI.char_unreserved?/1)

    case http_put_json("http://127.0.0.1:#{port}/json/new?#{encoded_url}") do
      {:ok, %{"webSocketDebuggerUrl" => _} = target} ->
        {:ok, target}

      {:ok, _target} ->
        first_page_target(port)

      {:error, _reason} ->
        first_page_target(port)
    end
  end

  defp first_page_target(port) do
    with {:ok, targets} <- http_get_json("http://127.0.0.1:#{port}/json/list"),
         %{"webSocketDebuggerUrl" => _} = target <-
           Enum.find(targets, fn
             %{"type" => "page", "webSocketDebuggerUrl" => _} -> true
             _target -> false
           end) do
      {:ok, target}
    else
      _ -> {:error, :target_not_found}
    end
  end

  defp cdp_command(socket, method, params \\ %{}, timeout \\ 10_000) do
    id = System.unique_integer([:positive])
    :ok = CDPConnection.send_command(socket, %{id: id, method: method, params: params})
    await_cdp_reply(socket, id, timeout)
  end

  defp await_cdp_reply(socket, id, timeout) do
    receive do
      {:cdp_frame, ^socket, %{"id" => ^id, "result" => result}} ->
        {:ok, result}

      {:cdp_frame, ^socket, %{"id" => ^id, "error" => error}} ->
        {:error, {:cdp_error, error}}

      {:cdp_frame, ^socket, _event_or_other} ->
        await_cdp_reply(socket, id, timeout)

      {:cdp_disconnect, ^socket, reason} ->
        {:error, {:cdp_disconnect, reason}}
    after
      timeout ->
        {:error, {:cdp_timeout, method_id: id}}
    end
  end

  defp evaluate(socket, expression) do
    with {:ok, %{"result" => result}} <-
           cdp_command(socket, "Runtime.evaluate", %{
             expression: expression,
             returnByValue: true,
             awaitPromise: true
           }) do
      {:ok, result["value"]}
    end
  end

  defp normalize_cookies(cookies) when is_list(cookies) do
    Enum.map(cookies, fn cookie ->
      %{
        name: cookie["name"],
        value: cookie["value"],
        domain: cookie["domain"],
        path: cookie["path"],
        secure: cookie["secure"],
        http_only: cookie["httpOnly"],
        same_site: cookie["sameSite"],
        expires: cookie["expires"]
      }
    end)
  end

  defp user_data_dir(opts) do
    case Keyword.get(opts, :user_data_dir) do
      nil ->
        Path.join(
          System.tmp_dir!(),
          "ex_undercover-solver-#{System.unique_integer([:positive])}"
        )

      path ->
        path
    end
  end

  defp cleanup_session(session) do
    stop_port(session.port_ref, session.os_pid)
    rm_user_data_dir(session.user_data_dir)
  end

  defp stop_port(port_ref, os_pid) do
    port_info = Port.info(port_ref)

    if port_info != nil do
      Port.close(port_ref)
    end

    if is_integer(os_pid) do
      System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
      Process.sleep(200)

      if process_alive?(os_pid) do
        System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
      end
    end
  rescue
    _error -> :ok
  end

  defp rm_user_data_dir(path) do
    File.rm_rf(path)
    :ok
  end

  defp browser_path(opts) do
    case Keyword.get(opts, :browser_path) || System.get_env("CHROME_BIN") || detect_browser() do
      nil -> {:error, :chrome_not_found}
      path -> {:ok, path}
    end
  end

  defp browser_version(browser_path) do
    case System.cmd(browser_path, ["--version"], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, status} ->
        {:error, {:browser_version_failed, status, output}}
    end
  end

  defp browser_major(version_output) do
    case Regex.run(~r/(\d+)\./, version_output, capture: :all_but_first) do
      [major] -> {:ok, String.to_integer(major)}
      _ -> {:error, {:browser_major_parse_failed, version_output}}
    end
  end

  defp detect_browser do
    Enum.find_value(@browser_candidates, &System.find_executable/1)
  end

  defp free_tcp_port do
    with {:ok, socket} <-
           :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true]),
         {:ok, port} <- :inet.port(socket) do
      :ok = :gen_tcp.close(socket)
      {:ok, port}
    end
  end

  defp start_httpc do
    :ok = Application.ensure_all_started(:inets) |> okify()
    :ok = Application.ensure_all_started(:ssl) |> okify()
  end

  defp http_get_json(url) do
    :httpc.request(:get, {to_charlist(url), []}, [], body_format: :binary)
    |> decode_http_json()
  end

  defp http_put_json(url) do
    request = {to_charlist(url), [], ~c"application/json", ~c""}

    :httpc.request(:put, request, [], body_format: :binary)
    |> decode_http_json()
  end

  defp decode_http_json({:ok, {{_http_version, status, _reason}, _headers, body}})
       when status in 200..299 do
    Jason.decode(body)
  end

  defp decode_http_json({:ok, {{_http_version, status, _reason}, _headers, body}}) do
    {:error, {:http_status, status, body}}
  end

  defp decode_http_json({:error, reason}), do: {:error, reason}

  defp okify({:ok, _apps}), do: :ok
  defp okify({:error, {:already_started, _app}}), do: :ok

  defp process_alive?(os_pid) do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  end

  defp page_text(socket) do
    evaluate(
      socket,
      """
      (() => {
        const body = document.body?.innerText;
        const root = document.documentElement?.innerText;
        return body || root || "";
      })()
      """
    )
  end
end
