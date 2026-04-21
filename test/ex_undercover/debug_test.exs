defmodule ExUndercover.DebugTest do
  use ExUnit.Case, async: true

  alias ExUndercover.Debug
  alias ExUndercover.Request

  test "builds request plans for tuple headers" do
    assert {:ok, plan} =
             Request.new("https://example.test/path",
               headers: [{"x-test", "1"}],
               body: ["o", "k"]
             )
             |> Debug.build_request_plan(connect_timeout: 1_000)

    assert fetch(plan, :method) == "get"
    assert fetch(plan, :url) == "https://example.test/path"
    assert {"x-test", "1"} in fetch(plan, :headers)
    assert fetch(plan, :profile_id) == "chrome_147"
  end

  defp fetch(plan, key) do
    Map.get(plan, Atom.to_string(key), Map.get(plan, key))
  end
end
