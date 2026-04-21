defmodule ExUndercover.TestSupport.HTTPServer do
  @moduledoc false

  def start_link(handler) when is_function(handler, 1) do
    parent = self()

    Task.start_link(fn ->
      {:ok, listen_socket} =
        :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

      {:ok, {_ip, port}} = :inet.sockname(listen_socket)
      send(parent, {:http_server_ready, self(), listen_socket, port})
      accept_loop(listen_socket, handler)
    end)
  end

  def url(port, path \\ "/"), do: "http://127.0.0.1:#{port}#{path}"

  defp accept_loop(listen_socket, handler) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        handle_connection(socket, handler)
        accept_loop(listen_socket, handler)

      {:error, :closed} ->
        :ok
    end
  end

  defp handle_connection(socket, handler) do
    with {:ok, request_blob} <- recv_until_headers(socket, ""),
         {:ok, request} <- parse_request(socket, request_blob),
         response <- normalize_response(handler.(request)),
         :ok <- :gen_tcp.send(socket, encode_response(response)) do
      :gen_tcp.close(socket)
    else
      _error ->
        :gen_tcp.close(socket)
    end
  end

  defp recv_until_headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 2_000) do
        {:ok, chunk} -> recv_until_headers(socket, acc <> chunk)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp parse_request(socket, request_blob) do
    [head, initial_body] = String.split(request_blob, "\r\n\r\n", parts: 2)
    [request_line | header_lines] = String.split(head, "\r\n", trim: true)
    [method, target, version] = String.split(request_line, " ", parts: 3)

    headers =
      Map.new(header_lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim_leading(value)}
      end)

    content_length =
      headers
      |> Map.get("content-length", "0")
      |> String.to_integer()

    with {:ok, body} <- recv_body(socket, initial_body, content_length) do
      {:ok,
       %{
         method: method,
         target: target,
         version: version,
         headers: headers,
         body: body
       }}
    end
  end

  defp recv_body(_socket, initial_body, 0), do: {:ok, initial_body}

  defp recv_body(socket, initial_body, content_length) do
    if byte_size(initial_body) >= content_length do
      {:ok, binary_part(initial_body, 0, content_length)}
    else
      case :gen_tcp.recv(socket, content_length - byte_size(initial_body), 2_000) do
        {:ok, chunk} -> recv_body(socket, initial_body <> chunk, content_length)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp normalize_response(%{} = response) do
    Map.merge(
      %{
        status: 200,
        headers: [{"content-type", "text/plain"}],
        body: ""
      },
      response
    )
  end

  defp encode_response(response) do
    status = Map.fetch!(response, :status)
    body = IO.iodata_to_binary(Map.get(response, :body, ""))

    headers =
      response
      |> Map.get(:headers, [])
      |> Enum.reject(fn {name, _value} -> String.downcase(name) == "content-length" end)
      |> Kernel.++([
        {"content-length", Integer.to_string(byte_size(body))},
        {"connection", "close"}
      ])

    [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " ",
      reason_phrase(status),
      "\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "\r\n",
      body
    ]
  end

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(403), do: "Forbidden"
  defp reason_phrase(429), do: "Too Many Requests"
  defp reason_phrase(503), do: "Service Unavailable"
  defp reason_phrase(_status), do: "OK"
end
