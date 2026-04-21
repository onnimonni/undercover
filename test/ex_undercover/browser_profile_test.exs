defmodule ExUndercover.BrowserProfileTest do
  use ExUnit.Case, async: true

  alias ExUndercover.BrowserProfile

  test "roundtrips through map conversion" do
    profile =
      BrowserProfile.from_map(%{
        "id" => "chrome_test",
        "browser" => "chrome",
        "version" => "147.0.0.0",
        "platform" => "linux",
        "headers" => [["user-agent", "test-agent"]],
        "transport" => %{
          tls: %{alpn: ["h2", "http/1.1"]},
          http2: %{settings: [["initial_window_size", 131_072]]}
        }
      })

    assert profile.id == :chrome_test
    assert profile.headers == [{"user-agent", "test-agent"}]

    assert BrowserProfile.to_map(profile) == %{
             "id" => "chrome_test",
             "browser" => "chrome",
             "version" => "147.0.0.0",
             "platform" => "linux",
             "headers" => [["user-agent", "test-agent"]],
             "transport" => %{
               "tls" => %{"alpn" => ["h2", "http/1.1"]},
               "http2" => %{"settings" => [["initial_window_size", 131_072]]}
             }
           }
  end

  test "accepts atom keyed maps" do
    profile =
      BrowserProfile.from_map(%{
        id: "chrome_atom_test",
        browser: :chrome,
        version: "147.0.0.0",
        platform: :linux,
        headers: [{"user-agent", "atom-agent"}],
        transport: %{tls: %{}, http2: %{}}
      })

    assert profile.id == :chrome_atom_test
    assert profile.browser == :chrome
    assert profile.headers == [{"user-agent", "atom-agent"}]
  end
end
