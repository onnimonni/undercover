defmodule ExUndercover.WireGuard.Manager do
  @moduledoc """
  Kernel WireGuard lifecycle.

  This project targets kernel WireGuard. On non-Linux hosts `wireguardex`
  falls back to a userspace backend, which is rejected by default here so the
  runtime does not silently violate that requirement.
  """

  alias ExUndercover.WireGuard.Config

  alias Wireguardex.DeviceConfigBuilder, as: DeviceBuilder
  alias Wireguardex.PeerConfigBuilder, as: PeerBuilder

  @spec ensure_started(Config.t()) :: :ok | {:error, term()}
  def ensure_started(%Config{} = cfg) do
    with :ok <- ensure_supported_backend(cfg),
         :ok <- ensure_device(cfg),
         :ok <- ensure_peers(cfg) do
      :ok
    end
  end

  @spec device_config(Config.t()) :: struct()
  def device_config(%Config{} = cfg) do
    DeviceBuilder.device_config()
    |> DeviceBuilder.private_key(cfg.private_key)
    |> maybe_listen_port(cfg.listen_port)
    |> maybe_fwmark(cfg.fwmark)
  end

  @spec peer_configs(Config.t()) :: [struct()]
  def peer_configs(%Config{} = cfg) do
    Enum.map(cfg.peers, fn peer_opts ->
      PeerBuilder.peer_config()
      |> PeerBuilder.public_key(Map.fetch!(peer_opts, :public_key))
      |> maybe_preshared_key(Map.get(peer_opts, :preshared_key))
      |> PeerBuilder.endpoint(Map.fetch!(peer_opts, :endpoint))
      |> PeerBuilder.allowed_ips(Map.get(peer_opts, :allowed_ips, Config.default_allowed_ips()))
      |> maybe_keepalive(Map.get(peer_opts, :persistent_keepalive_interval))
    end)
  end

  defp ensure_supported_backend(%Config{allow_userspace: true}), do: :ok

  defp ensure_supported_backend(%Config{}) do
    case :os.type() do
      {:unix, :linux} ->
        :ok

      {family, os} ->
        {:error, {:userspace_wireguard_disabled, %{os_family: family, os: os}}}
    end
  end

  defp ensure_device(%Config{} = cfg) do
    Wireguardex.set_device(device_config(cfg), cfg.interface)
  end

  defp ensure_peers(%Config{} = cfg) do
    Enum.reduce_while(peer_configs(cfg), :ok, fn peer, :ok ->
      case Wireguardex.add_peer(cfg.interface, peer) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp maybe_listen_port(builder, nil), do: builder
  defp maybe_listen_port(builder, port), do: DeviceBuilder.listen_port(builder, port)

  defp maybe_fwmark(builder, nil), do: builder
  defp maybe_fwmark(builder, mark), do: DeviceBuilder.fwmark(builder, mark)

  defp maybe_preshared_key(builder, nil), do: builder

  defp maybe_preshared_key(builder, preshared_key),
    do: PeerBuilder.preshared_key(builder, preshared_key)

  defp maybe_keepalive(builder, nil), do: builder

  defp maybe_keepalive(builder, seconds),
    do: PeerBuilder.persistent_keepalive_interval(builder, seconds)
end
