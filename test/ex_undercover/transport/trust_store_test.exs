defmodule ExUndercover.Transport.TrustStoreTest do
  use ExUnit.Case, async: false

  alias ExUndercover.Transport.TrustStore

  setup do
    path = TrustStore.installed_path()
    original = if File.exists?(path), do: File.read!(path)

    on_exit(fn ->
      case original do
        nil -> File.rm(path)
        contents -> File.write!(path, contents)
      end
    end)

    :ok
  end

  test "installs bundle and applies it when no bundle is present in metadata" do
    source_path =
      Path.join(
        System.tmp_dir!(),
        "ex_undercover-test-ca-#{System.unique_integer([:positive])}.pem"
      )

    File.write!(source_path, "-----BEGIN CERTIFICATE-----\nTEST\n-----END CERTIFICATE-----\n")

    installed_path = TrustStore.install!(source_path)
    assert File.exists?(installed_path)

    assert %{"ca_cert_file" => ^installed_path} = TrustStore.apply_default_bundle(%{})

    assert %{ca_cert_file: "already-set"} =
             TrustStore.apply_default_bundle(%{ca_cert_file: "already-set"})
  end
end
