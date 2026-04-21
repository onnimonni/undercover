defmodule ExUndercover.ClientTest do
  use ExUnit.Case, async: false

  alias ExUndercover.Client
  alias ExUndercover.Request
  alias ExUndercover.TestSupport.HTTPServer

  test "executes requests through the client api directly" do
    {:ok, pid} =
      HTTPServer.start_link(fn request ->
        %{
          status: 200,
          body: "#{request.method}:#{request.body}:#{Map.get(request.headers, "x-client")}"
        }
      end)

    port =
      receive do
        {:http_server_ready, ^pid, listen_socket, port} ->
          on_exit(fn ->
            :gen_tcp.close(listen_socket)
            Process.exit(pid, :kill)
          end)

          port
      after
        2_000 ->
          flunk("http test server failed to start")
      end

    assert {:ok, response} =
             Request.new(
               HTTPServer.url(port),
               method: :post,
               headers: [{"x-client", "1"}],
               body: "payload",
               browser_profile: :chrome_latest
             )
             |> Client.request()

    assert response.status == 200
    assert response.body == "POST:payload:1"
    assert is_binary(response.remote_address)
  end
end
