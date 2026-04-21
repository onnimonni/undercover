defmodule ExUndercover.ProfileTest do
  use ExUnit.Case, async: true

  alias ExUndercover.Profile

  test "chrome_latest resolves through the alias store" do
    profile = Profile.chrome_latest()

    assert profile.id == :chrome_147
    assert profile.browser == :chrome
    assert is_binary(profile.version)
  end

  test "known_profiles includes latest alias and bundled profile" do
    assert :chrome_latest in Profile.known_profiles()
    assert :chrome_147 in Profile.known_profiles()
  end

  test "resolve returns browser profiles unchanged" do
    profile = Profile.chrome_latest()
    assert Profile.resolve(profile) == profile
  end

  test "resolve accepts builtin profile ids as strings" do
    assert Profile.resolve("chrome_147").id == :chrome_147
  end

  test "resolve accepts builtin profile ids as atoms" do
    assert Profile.resolve(:chrome_147).id == :chrome_147
    assert Profile.resolve(:chrome_latest).id == :chrome_147
  end

  test "transport map flattens tls and http2 sections" do
    transport_map =
      :chrome_latest
      |> Profile.resolve()
      |> Profile.to_transport_map()

    assert transport_map["id"] == "chrome_147"
    assert is_map(transport_map["tls"])
    assert is_map(transport_map["http2"])
    refute Map.has_key?(transport_map, "transport")
  end

  test "resolve raises for unknown profiles" do
    assert_raise ArgumentError, ~r/unknown browser profile/, fn ->
      Profile.resolve("missing_profile")
    end
  end
end
