defmodule Mix.Tasks.ExUndercover.InstallCaBundle do
  use Mix.Task

  @shortdoc "Install a custom PEM CA bundle for request verification"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [source_path] ->
        target = ExUndercover.Transport.TrustStore.install!(source_path)
        Mix.shell().info("installed CA bundle at #{target}")

      _ ->
        Mix.raise("usage: mix ex_undercover.install_ca_bundle SOURCE_PEM_PATH")
    end
  end
end
