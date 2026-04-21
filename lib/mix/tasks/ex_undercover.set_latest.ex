defmodule Mix.Tasks.ExUndercover.SetLatest do
  use Mix.Task

  @shortdoc "Point chrome_latest alias at a specific profile"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [profile_id] ->
        ExUndercover.Profile.Store.write_aliases!(%{"chrome_latest" => profile_id})
        Mix.shell().info("chrome_latest -> #{profile_id}")

      _ ->
        Mix.raise("usage: mix ex_undercover.set_latest PROFILE_ID")
    end
  end
end
