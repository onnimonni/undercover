defmodule ExUndercover.Client do
  @moduledoc """
  Elixir-facing HTTP client API.

  Request execution is delegated to the Rust NIF transport. This module keeps
  the Elixir API stable while the native backend evolves.
  """

  alias ExUndercover.Nif
  alias ExUndercover.Profile
  alias ExUndercover.Request
  alias ExUndercover.Response
  alias ExUndercover.Transport.TrustStore

  @spec request(Request.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def request(%Request{} = request, opts \\ []) do
    profile = Profile.resolve(request.browser_profile)

    metadata =
      request.metadata
      |> Map.merge(Map.new(opts))
      |> TrustStore.apply_default_bundle()

    payload = %{
      method: to_string(request.method),
      url: request.url,
      headers: normalize_headers(request.headers),
      body: encode_body(request.body),
      profile: to_string(profile.id),
      profile_data: Profile.to_transport_map(profile),
      proxy_tunnel: request.proxy_tunnel,
      metadata: metadata
    }

    with {:ok, response_map} <- Nif.request(Jason.encode!(payload)),
         {:ok, response} <- __MODULE__.ResponseBuilder.from_map(response_map, profile.id) do
      {:ok, response}
    end
  end

  defp encode_body(nil), do: nil
  defp encode_body(body) when is_binary(body), do: body
  defp encode_body(body), do: IO.iodata_to_binary(body)

  defp normalize_headers(headers) do
    Enum.map(headers, fn
      {name, value} -> [to_string(name), to_string(value)]
      [name, value] -> [to_string(name), to_string(value)]
    end)
  end

  defmodule ResponseBuilder do
    alias ExUndercover.Response

    @spec from_map(map(), atom()) :: {:ok, Response.t()} | {:error, term()}
    def from_map(map, profile_id) when is_map(map) do
      status = Map.get(map, "status", Map.get(map, :status))
      headers = Map.get(map, "headers", Map.get(map, :headers))
      body = Map.get(map, "body", Map.get(map, :body))
      remote_address = Map.get(map, "remote_address", Map.get(map, :remote_address))
      diagnostics = Map.get(map, "diagnostics", Map.get(map, :diagnostics))

      if is_integer(status) and is_list(headers) and is_binary(body) and is_map(diagnostics) do
        {:ok,
         %Response{
           status: status,
           headers: normalize_headers(headers),
           body: body,
           browser_profile: profile_id,
           remote_address: remote_address,
           diagnostics: diagnostics
         }}
      else
        {:error, :invalid_response}
      end
    end

    def from_map(_map, _profile_id), do: {:error, :invalid_response}

    defp normalize_headers(headers) when is_list(headers) do
      Enum.map(headers, fn
        [k, v] -> {to_string(k), to_string(v)}
        {k, v} -> {to_string(k), to_string(v)}
      end)
    end
  end
end
