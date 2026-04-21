defmodule Mix.Tasks.ExUndercover.VerifyPeet do
  use Mix.Task

  @shortdoc "Verify Chrome impersonation against tls.peet.ws"

  @expected_ja4 "t13d1717h2_5b57614c22b0_3cbfd9057e0d"
  @expected_akamai "1:65536;2:0;4:131072;5:16384|12517377|0|m,p,a,s"
  @expected_akamai_hash "6ea73faa8fc5aac76bded7bd238f6433"
  @expected_header_order [
    ":method",
    ":path",
    ":authority",
    ":scheme",
    "sec-ch-ua",
    "sec-ch-ua-mobile",
    "sec-ch-ua-platform",
    "upgrade-insecure-requests",
    "user-agent",
    "accept-language",
    "accept",
    "sec-fetch-site",
    "sec-fetch-mode",
    "sec-fetch-user",
    "sec-fetch-dest",
    "accept-encoding",
    "priority"
  ]

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    request =
      ExUndercover.Request.new("https://tls.peet.ws/api/all", browser_profile: :chrome_latest)

    with {:ok, response} <- ExUndercover.request(request, solver: false),
         {:ok, payload} <- Jason.decode(response.body),
         :ok <- verify_status(response.status),
         :ok <- verify_http_version(payload),
         :ok <- verify_user_agent(payload),
         :ok <- verify_ja4(payload),
         :ok <- verify_akamai(payload),
         :ok <- verify_headers(payload) do
      Mix.shell().info("""
      tls.peet.ws verification passed
      ja4=#{get_in(payload, ["tls", "ja4"])}
      akamai_hash=#{get_in(payload, ["http2", "akamai_fingerprint_hash"])}
      """)
    else
      {:error, reason} -> Mix.raise(format_error(reason))
    end
  end

  defp verify_status(200), do: :ok
  defp verify_status(status), do: {:error, {:unexpected_status, status}}

  defp verify_http_version(%{"http_version" => "h2"}), do: :ok

  defp verify_http_version(payload) do
    {:error, {:unexpected_http_version, Map.get(payload, "http_version")}}
  end

  defp verify_user_agent(%{"user_agent" => user_agent}) do
    if String.contains?(user_agent, "Chrome/147.0.0.0") do
      :ok
    else
      {:error, {:unexpected_user_agent, user_agent}}
    end
  end

  defp verify_user_agent(payload),
    do: {:error, {:unexpected_user_agent, Map.get(payload, "user_agent")}}

  defp verify_ja4(%{"tls" => %{"ja4" => @expected_ja4}}), do: :ok

  defp verify_ja4(payload) do
    {:error, {:unexpected_ja4, get_in(payload, ["tls", "ja4"])}}
  end

  defp verify_akamai(%{
         "http2" => %{
           "akamai_fingerprint" => @expected_akamai,
           "akamai_fingerprint_hash" => @expected_akamai_hash
         }
       }),
       do: :ok

  defp verify_akamai(payload) do
    {:error,
     {:unexpected_akamai,
      %{
        akamai: get_in(payload, ["http2", "akamai_fingerprint"]),
        akamai_hash: get_in(payload, ["http2", "akamai_fingerprint_hash"])
      }}}
  end

  defp verify_headers(%{"http2" => %{"sent_frames" => frames}}) when is_list(frames) do
    header_names =
      frames
      |> Enum.find_value([], fn
        %{"frame_type" => "HEADERS", "headers" => headers} ->
          Enum.map(headers, &header_name/1)

        _frame ->
          false
      end)

    if header_names == @expected_header_order do
      :ok
    else
      {:error, {:unexpected_header_order, header_names}}
    end
  end

  defp verify_headers(_payload), do: {:error, :missing_header_frame}

  defp header_name(header) when is_binary(header) do
    case String.split(header, ": ", parts: 2) do
      [name, _value] -> name
      [name] -> name
    end
  end

  defp format_error({tag, value}), do: "#{tag}: #{inspect(value, pretty: true)}"
  defp format_error(reason), do: inspect(reason, pretty: true)
end
