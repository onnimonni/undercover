defmodule ExUndercover.Client.ResponseBuilderTest do
  use ExUnit.Case, async: true

  alias ExUndercover.Client.ResponseBuilder

  test "accepts atom-keyed nif maps" do
    assert {:ok, response} =
             ResponseBuilder.from_map(
               %{
                 status: 200,
                 headers: [{"content-type", "text/plain"}, ["server", "test"]],
                 body: "ok",
                 remote_address: "127.0.0.1:80",
                 diagnostics: %{"transport" => "test"}
               },
               :chrome_147
             )

    assert response.status == 200
    assert response.headers == [{"content-type", "text/plain"}, {"server", "test"}]
    assert response.body == "ok"
    assert response.browser_profile == :chrome_147
  end

  test "rejects incomplete maps" do
    assert {:error, :invalid_response} =
             ResponseBuilder.from_map(%{status: 200, headers: []}, :chrome_147)
  end
end
