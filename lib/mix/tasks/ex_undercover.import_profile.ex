defmodule Mix.Tasks.ExUndercover.ImportProfile do
  use Mix.Task

  @shortdoc "Import a browser profile JSON file into priv/profiles"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, _invalid} =
      OptionParser.parse(args, strict: [latest: :boolean])

    case positional do
      [input_path] ->
        body = File.read!(input_path)
        decoded = Jason.decode!(body)
        ExUndercover.Profile.Store.write_profile!(decoded)

        if opts[:latest] do
          ExUndercover.Profile.Store.write_aliases!(%{"chrome_latest" => decoded["id"]})
        end

        Mix.shell().info("imported #{decoded["id"]} from #{input_path}")

      _ ->
        Mix.raise("usage: mix ex_undercover.import_profile INPUT_PATH [--latest]")
    end
  end
end
