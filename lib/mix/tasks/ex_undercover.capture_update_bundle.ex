defmodule Mix.Tasks.ExUndercover.CaptureUpdateBundle do
  use Mix.Task

  @shortdoc "Capture all artifacts needed to update a Chrome profile"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [
          profile: :string,
          browser_path: :string,
          output_dir: :string,
          solve_wait_ms: :integer
        ]
      )

    profile_id = String.to_atom(opts[:profile] || "chrome_latest")

    with profile <- ExUndercover.Profile.resolve(profile_id),
         {:ok, browser} <-
           ExUndercover.Solver.Chrome.browser_info(browser_path: opts[:browser_path]),
         {:ok, client_hello} <-
           ExUndercover.Capture.ClientHello.capture(
             browser_profile: profile_id,
             browser_path: opts[:browser_path]
           ),
         {:ok, solver_report} <- solver_report(profile_id, opts),
         {:ok, fast_report} <- fast_report(profile_id) do
      output_dir =
        opts[:output_dir] ||
          Application.app_dir(:ex_undercover, "priv/captures/chrome#{browser.major}")

      File.mkdir_p!(output_dir)

      write_json(
        Path.join(output_dir, "summary.json"),
        summary(profile, browser, client_hello, fast_report, solver_report)
      )

      write_json(Path.join(output_dir, "solver_report.json"), solver_report)
      write_json(Path.join(output_dir, "fast_report.json"), fast_report)
      write_json(Path.join(output_dir, "clienthello.json"), client_hello)
      File.write!(Path.join(output_dir, "clienthello.hex"), client_hello.client_hello_hex <> "\n")

      Mix.shell().info("wrote update bundle to #{output_dir}")
    else
      {:error, reason} ->
        Mix.raise("capture update bundle failed: #{inspect(reason, pretty: true)}")
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
    with {:ok, result} <-
           ExUndercover.Solver.Chrome.solve(
             "https://tls.peet.ws/api/all",
             browser_profile: profile_id,
             browser_path: opts[:browser_path],
             solve_wait_ms: opts[:solve_wait_ms] || 4_000
           ),
         body when is_binary(body) <- result[:body_text],
         {:ok, payload} <- Jason.decode(body) do
      {:ok, payload}
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :solver_body_missing}
      other -> {:error, {:solver_unexpected_body, other}}
    end
  end

  defp summary(profile, browser, client_hello, fast_report, solver_report) do
    %{
      generated_at: DateTime.utc_now(),
      profile: %{
        id: profile.id,
        version: profile.version
      },
      browser: browser,
      alignment: %{
        profile_major: profile_major(profile),
        browser_major: browser.major,
        major_match?: profile_major(profile) == browser.major,
        fast_ja4: get_in(fast_report, ["tls", "ja4"]),
        solver_ja4: get_in(solver_report, ["tls", "ja4"]),
        fast_akamai_hash: get_in(fast_report, ["http2", "akamai_fingerprint_hash"]),
        solver_akamai_hash: get_in(solver_report, ["http2", "akamai_fingerprint_hash"]),
        fast_header_order: header_order(fast_report),
        solver_header_order: header_order(solver_report)
      },
      client_hello: %{
        ja3: client_hello.ja3,
        ja3_hash: client_hello.ja3_hash,
        sni: client_hello.sni,
        alpn: client_hello.alpn,
        extension_ids: client_hello.extension_ids
      }
    }
    |> stringify()
  end

  defp profile_major(profile) do
    profile.id
    |> Atom.to_string()
    |> String.split("_")
    |> List.last()
    |> String.to_integer()
  end

  defp header_order(payload) do
    payload
    |> get_in(["http2", "sent_frames"])
    |> Enum.find_value([], &headers_frame/1)
  end

  defp write_json(path, value) do
    File.write!(path, Jason.encode_to_iodata!(stringify(value), pretty: true))
  end

  defp stringify(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp stringify(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

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
