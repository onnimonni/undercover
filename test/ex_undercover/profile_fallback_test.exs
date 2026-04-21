defmodule ExUndercover.ProfileFallbackTest do
  use ExUnit.Case, async: false

  alias ExUndercover.Profile
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

  test "falls back to the bundled chrome profile when the alias file is empty" do
    assert :ok = Store.write_aliases!(%{})
    assert Profile.chrome_latest().id == :chrome_147
    refute :chrome_latest in Profile.known_profiles()
  end

  test "raises when the profile store contains invalid json" do
    path = Store.profile_path("broken_profile")
    File.write!(path, "{not-json")

    on_exit(fn ->
      File.rm(path)
    end)

    assert_raise ArgumentError, ~r/failed to load browser profile/, fn ->
      Profile.resolve("broken_profile")
    end
  end
end
