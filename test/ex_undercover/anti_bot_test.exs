defmodule ExUndercover.AntiBotTest do
  use ExUnit.Case, async: true

  alias ExUndercover.AntiBot
  alias ExUndercover.Response

  test "classifies successful responses" do
    assert {:ok, %{reason: "request succeeded"}} =
             AntiBot.classify(%Response{status: 200, headers: [], body: "ok"})
  end

  test "classifies cloudflare style challenges" do
    assert {:challenge, %{reason: "cloudflare challenge header"}} =
             AntiBot.classify(%Response{
               status: 403,
               headers: [{"cf-mitigated", "challenge"}],
               body: "blocked"
             })
  end

  test "classifies access denied without known challenge markers" do
    assert {:access_denied, %{reason: "upstream denied request without known challenge markers"}} =
             AntiBot.classify(%Response{status: 403, headers: [], body: "denied"})
  end

  test "classifies rate limiting" do
    assert {:rate_limited, %{reason: "429 rate limit"}} =
             AntiBot.classify(%Response{status: 429, headers: [], body: "slow down"})
  end

  test "classifies server errors" do
    assert {:server_error, %{reason: "upstream server error"}} =
             AntiBot.classify(%Response{status: 503, headers: [], body: "oops"})
  end

  test "classifies unknown statuses" do
    assert {:unknown, %{reason: "unclassified upstream response"}} =
             AntiBot.classify(%Response{status: 418, headers: [], body: "teapot"})
  end

  test "detects akamai style challenges" do
    assert {:challenge, %{reason: "akamai header pair"}} =
             AntiBot.classify(%Response{
               status: 403,
               headers: [{"server", "AkamaiGHost"}, {"x-iinfo", "test"}],
               body: "blocked"
             })
  end

  test "detects datadome style challenge bodies" do
    assert {:challenge, %{reason: "datadome body marker"}} =
             AntiBot.classify(%Response{
               status: 503,
               headers: [],
               body: "<html>datadome challenge</html>"
             })
  end
end
