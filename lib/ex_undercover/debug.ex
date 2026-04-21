defmodule ExUndercover.Debug do
  @moduledoc """
  Native transport inspection helpers.
  """

  alias ExUndercover.Nif
  alias ExUndercover.Profile
  alias ExUndercover.Request

  def build_request_plan(request_or_url, opts \\ [])

  def build_request_plan(%Request{} = request, opts) do
    profile = Profile.resolve(request.browser_profile)

    Nif.build_request_plan(
      Jason.encode!(%{
        method: to_string(request.method),
        url: request.url,
        headers: normalize_headers(request.headers),
        body: body(request.body),
        profile: to_string(profile.id),
        profile_data: Profile.to_transport_map(profile),
        proxy_tunnel: request.proxy_tunnel,
        metadata: Map.merge(request.metadata, Map.new(opts))
      })
    )
  end

  def build_request_plan(url, opts) when is_binary(url) do
    url
    |> Request.new(opts)
    |> build_request_plan([])
  end

  defp body(nil), do: nil
  defp body(payload) when is_binary(payload), do: payload
  defp body(payload), do: IO.iodata_to_binary(payload)

  defp normalize_headers(headers) do
    Enum.map(headers, fn
      {name, value} -> [to_string(name), to_string(value)]
      [name, value] -> [to_string(name), to_string(value)]
    end)
  end
end
