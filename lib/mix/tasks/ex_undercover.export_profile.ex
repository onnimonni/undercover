defmodule Mix.Tasks.ExUndercover.ExportProfile do
  use Mix.Task

  @shortdoc "Export a browser profile as JSON"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [profile_id] ->
        export(profile_id, nil)

      [profile_id, output_path] ->
        export(profile_id, output_path)

      _ ->
        Mix.raise("usage: mix ex_undercover.export_profile PROFILE_ID [OUTPUT_PATH]")
    end
  end

  defp export(profile_id, nil) do
    profile =
      profile_id
      |> String.to_atom()
      |> ExUndercover.Profile.resolve()
      |> ExUndercover.Profile.to_transport_map()

    Mix.shell().info(Jason.encode_to_iodata!(profile, pretty: true))
  end

  defp export(profile_id, output_path) do
    profile =
      profile_id
      |> String.to_atom()
      |> ExUndercover.Profile.resolve()
      |> ExUndercover.Profile.to_transport_map()

    File.write!(output_path, Jason.encode_to_iodata!(profile, pretty: true))
    Mix.shell().info("exported #{profile_id} to #{output_path}")
  end
end
