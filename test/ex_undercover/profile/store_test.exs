defmodule ExUndercover.Profile.StoreTest do
  use ExUnit.Case, async: false

  alias ExUndercover.BrowserProfile
  alias ExUndercover.Profile.Store

  setup do
    alias_path = Store.aliases_path()
    original_aliases = if File.exists?(alias_path), do: File.read!(alias_path)

    on_exit(fn ->
      case original_aliases do
        nil -> File.rm(alias_path)
        body -> File.write!(alias_path, body)
      end
    end)

    :ok
  end

  test "loads bundled profiles and aliases" do
    assert :chrome_147 in Store.list()
    assert Store.resolve_alias(:chrome_latest) == :chrome_147
    assert {:ok, %BrowserProfile{id: :chrome_147}} = Store.load(:chrome_147)
  end

  test "writes and reloads profiles" do
    profile =
      BrowserProfile.from_map(%{
        "id" => "chrome_store_test",
        "browser" => "chrome",
        "version" => "147.0.0.0",
        "platform" => "linux",
        "headers" => [["user-agent", "store-test"]],
        "transport" => %{"tls" => %{}, "http2" => %{}}
      })

    path = Store.profile_path(profile.id)

    on_exit(fn ->
      File.rm(path)
    end)

    assert :ok = Store.write_profile!(profile)

    assert {:ok, %BrowserProfile{id: :chrome_store_test} = loaded} =
             Store.load(:chrome_store_test)

    assert loaded.headers == [{"user-agent", "store-test"}]
  end

  test "writes aliases as strings" do
    assert :ok = Store.write_aliases!(%{chrome_latest: :chrome_147, chrome_beta: "chrome_147"})
    assert Store.aliases() == %{"chrome_beta" => "chrome_147", "chrome_latest" => "chrome_147"}
  end
end
