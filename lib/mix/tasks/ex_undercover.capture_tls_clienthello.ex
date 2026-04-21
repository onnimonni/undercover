defmodule Mix.Tasks.ExUndercover.CaptureTlsClienthello do
  use Mix.Task

  @shortdoc "Capture real Chrome ClientHello against a local listener"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [
          output: :string,
          profile: :string,
          browser_path: :string,
          timeout_ms: :integer
        ]
      )

    capture_opts =
      []
      |> put_opt(:browser_profile, opts[:profile])
      |> put_opt(:browser_path, opts[:browser_path])
      |> put_opt(:timeout_ms, opts[:timeout_ms])

    case ExUndercover.Capture.ClientHello.capture(capture_opts) do
      {:ok, capture} ->
        write_capture(capture, opts[:output])

      {:error, reason} ->
        Mix.raise("capture failed: #{inspect(reason, pretty: true)}")
    end
  end

  defp write_capture(capture, nil) do
    major = capture[:browser_major]
    root = Application.app_dir(:ex_undercover, "priv/captures")
    File.mkdir_p!(root)

    hex_path = Path.join(root, "chrome#{major}.clienthello.hex")
    json_path = Path.join(root, "chrome#{major}.clienthello.json")

    File.write!(hex_path, capture[:client_hello_hex] <> "\n")
    File.write!(json_path, Jason.encode_to_iodata!(capture, pretty: true))

    Mix.shell().info("wrote #{hex_path}")
    Mix.shell().info("wrote #{json_path}")
  end

  defp write_capture(capture, output_path) do
    File.write!(output_path, Jason.encode_to_iodata!(capture, pretty: true))
    Mix.shell().info("wrote #{output_path}")
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
