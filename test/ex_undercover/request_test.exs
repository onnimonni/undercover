defmodule ExUndercover.RequestTest do
  use ExUnit.Case, async: true

  alias ExUndercover.Request

  test "builds request with defaults" do
    request = Request.new("https://example.test")

    assert request.method == :get
    assert request.url == "https://example.test"
    assert request.headers == []
    assert request.browser_profile == :chrome_latest
    assert request.metadata == %{}
  end

  test "builds request with explicit values" do
    request =
      Request.new("https://example.test", method: :post, headers: [{"x-test", "1"}], body: "ok")

    assert request.method == :post
    assert request.headers == [{"x-test", "1"}]
    assert request.body == "ok"
  end
end
