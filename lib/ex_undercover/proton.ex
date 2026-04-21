defmodule ExUndercover.Proton do
  @moduledoc """
  Proton VPN helpers for WireGuard configs and endpoint selection.
  """

  alias ExUndercover.WireGuard.Config

  @default_snapshot_path "/var/lib/stuffix/proton/snapshot.json"
  @default_endpoint_port 51820

  @type endpoint :: %{
          name: binary(),
          tier: non_neg_integer(),
          country: binary(),
          city: binary() | nil,
          domain: binary() | nil,
          entry_ip: binary(),
          exit_ip: binary(),
          pubkey: binary()
        }

  @spec list_endpoints(keyword()) :: {:ok, [endpoint()]} | {:error, term()}
  def list_endpoints(opts \\ []) do
    path = Keyword.get(opts, :snapshot_path, default_snapshot_path())

    with {:ok, body} <- File.read(path),
         {:ok, payload} <- Jason.decode(body) do
      {:ok,
       extract_endpoints(payload)
       |> Enum.map(&normalize_endpoint/1)
       |> Enum.reject(&is_nil/1)
       |> Enum.filter(&match_endpoint?(&1, opts))
       |> dedupe_endpoints()}
    end
  end

  @spec choose_endpoint(keyword()) :: {:ok, endpoint()} | {:error, term()}
  def choose_endpoint(opts \\ []) do
    with {:ok, endpoints} <- list_endpoints(opts),
         {:ok, endpoint} <- first_endpoint(endpoints, opts) do
      {:ok, endpoint}
    end
  end

  @spec build_wireguard_config(binary(), keyword()) :: {:ok, Config.t()} | {:error, term()}
  def build_wireguard_config(conf_path, opts \\ []) do
    with {:ok, config} <- Config.from_file(conf_path, opts),
         {:ok, endpoint} <- choose_endpoint(opts) do
      {:ok,
       Config.with_peer(config,
         public_key: endpoint.pubkey,
         endpoint:
           "#{endpoint.entry_ip}:#{Keyword.get(opts, :endpoint_port, @default_endpoint_port)}",
         allowed_ips: Keyword.get(opts, :allowed_ips, Config.default_allowed_ips()),
         persistent_keepalive_interval:
           Keyword.get(
             opts,
             :persistent_keepalive_interval,
             Config.default_persistent_keepalive()
           )
       )}
    end
  end

  @spec default_snapshot_path() :: binary()
  def default_snapshot_path, do: @default_snapshot_path

  defp first_endpoint([], _opts), do: {:error, :no_matching_endpoint}

  defp first_endpoint(endpoints, opts) do
    case Keyword.get(opts, :name) do
      name when is_binary(name) ->
        case Enum.find(endpoints, &(&1.name == name)) do
          nil -> {:error, {:endpoint_not_found, name}}
          endpoint -> {:ok, endpoint}
        end

      _other ->
        {:ok, hd(endpoints)}
    end
  end

  defp match_endpoint?(endpoint, opts) do
    country = Keyword.get(opts, :country)
    tier = Keyword.get(opts, :tier)
    city = Keyword.get(opts, :city)

    match_country?(endpoint, country) and match_tier?(endpoint, tier) and
      match_city?(endpoint, city)
  end

  defp match_country?(_endpoint, nil), do: true
  defp match_country?(endpoint, country), do: endpoint.country == String.upcase(country)

  defp match_tier?(_endpoint, nil), do: true
  defp match_tier?(endpoint, tier), do: endpoint.tier == tier

  defp match_city?(_endpoint, nil), do: true
  defp match_city?(endpoint, city), do: endpoint.city == city

  defp normalize_endpoint(
         %{
           "name" => name,
           "tier" => tier,
           "country" => country,
           "entry_ip" => entry_ip,
           "exit_ip" => exit_ip,
           "pubkey" => pubkey
         } = raw
       ) do
    %{
      name: name,
      tier: tier,
      country: country,
      city: raw["city"],
      domain: raw["domain"],
      entry_ip: entry_ip,
      exit_ip: exit_ip,
      pubkey: pubkey
    }
  end

  defp normalize_endpoint(_raw), do: nil

  defp dedupe_endpoints(endpoints) do
    endpoints
    |> Enum.uniq_by(fn endpoint -> {endpoint.name, endpoint.entry_ip, endpoint.pubkey} end)
    |> Enum.sort_by(fn endpoint -> {endpoint.tier, endpoint.name} end)
  end

  defp extract_endpoints(list) when is_list(list), do: list
  defp extract_endpoints(%{"servers" => servers}) when is_list(servers), do: servers
  defp extract_endpoints(_payload), do: []
end
