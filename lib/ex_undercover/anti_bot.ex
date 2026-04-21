defmodule ExUndercover.AntiBot do
  @moduledoc """
  Response classification for antibot escalation.
  """

  alias ExUndercover.Response

  @type classification ::
          :ok
          | :rate_limited
          | :challenge
          | :access_denied
          | :server_error
          | :unknown

  @spec classify(Response.t()) :: {classification(), map()}
  def classify(%Response{status: status, headers: headers, body: body}) do
    headers = normalize_headers(headers)

    cond do
      status == 429 ->
        {:rate_limited, %{reason: "429 rate limit"}}

      challenge?(status, headers, body) ->
        {:challenge, %{reason: challenge_reason(headers, body)}}

      status in [401, 403] ->
        {:access_denied, %{reason: "upstream denied request without known challenge markers"}}

      status >= 500 ->
        {:server_error, %{reason: "upstream server error"}}

      status >= 200 and status < 400 ->
        {:ok, %{reason: "request succeeded"}}

      true ->
        {:unknown, %{reason: "unclassified upstream response"}}
    end
  end

  defp challenge?(status, headers, body) when status in [403, 503] do
    has_header?(headers, "cf-mitigated") or
      server_contains?(headers, "cloudflare") or
      has_header?(headers, "x-datadome") or
      has_header?(headers, "x-dd-b") or
      has_header?(headers, "x-sucuri-id") or
      akamaiish?(headers) or
      body_contains?(body, "cf-chl-") or
      body_contains?(body, "/cdn-cgi/challenge-platform/") or
      body_contains?(body, "datadome") or
      body_contains?(body, "_abck")
  end

  defp challenge?(_status, _headers, _body), do: false

  defp challenge_reason(headers, body) do
    cond do
      has_header?(headers, "cf-mitigated") -> "cloudflare challenge header"
      server_contains?(headers, "cloudflare") -> "cloudflare server marker"
      has_header?(headers, "x-datadome") -> "datadome header"
      has_header?(headers, "x-dd-b") -> "datadome block header"
      has_header?(headers, "x-sucuri-id") -> "sucuri header"
      akamaiish?(headers) -> "akamai header pair"
      body_contains?(body, "/cdn-cgi/challenge-platform/") -> "cloudflare challenge body"
      body_contains?(body, "cf-chl-") -> "cloudflare challenge token"
      body_contains?(body, "datadome") -> "datadome body marker"
      body_contains?(body, "_abck") -> "akamai cookie marker"
      true -> "unknown challenge marker"
    end
  end

  defp akamaiish?(headers) do
    has_header?(headers, "x-iinfo") or server_contains?(headers, "akamai")
  end

  defp server_contains?(headers, needle) do
    headers
    |> Map.get("server", "")
    |> String.downcase()
    |> String.contains?(needle)
  end

  defp has_header?(headers, name), do: Map.has_key?(headers, String.downcase(name))

  defp body_contains?(body, needle) when is_binary(body) do
    String.contains?(String.downcase(body), String.downcase(needle))
  end

  defp body_contains?(_, _), do: false

  defp normalize_headers(headers) do
    Map.new(headers, fn {k, v} -> {String.downcase(k), v} end)
  end
end
