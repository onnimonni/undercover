defmodule ExUndercover.WireGuard.Config do
  @moduledoc """
  WireGuard configuration shared by the runtime and Proton helpers.
  """

  @default_address "10.2.0.2/32"
  @default_dns ["10.2.0.1"]
  @default_mtu 1420
  @default_persistent_keepalive 25
  @default_allowed_ips ["0.0.0.0/0", "::/0"]

  @enforce_keys [:interface, :private_key]
  defstruct interface: nil,
            private_key: nil,
            address: nil,
            addresses: [],
            dns: [],
            peers: [],
            listen_port: nil,
            fwmark: nil,
            mtu: @default_mtu,
            allow_userspace: false

  @type peer :: %{
          optional(:public_key) => binary(),
          optional(:preshared_key) => binary(),
          optional(:endpoint) => binary(),
          optional(:allowed_ips) => [binary()],
          optional(:persistent_keepalive_interval) => pos_integer() | nil
        }

  @type t :: %__MODULE__{
          interface: binary(),
          private_key: binary(),
          address: binary() | nil,
          addresses: [binary()],
          dns: [binary()],
          peers: [peer()],
          listen_port: pos_integer() | nil,
          fwmark: non_neg_integer() | nil,
          mtu: pos_integer(),
          allow_userspace: boolean()
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    addresses =
      opts
      |> Keyword.get(:addresses, [])
      |> normalize_addresses(Keyword.get(opts, :address))

    %__MODULE__{
      interface: Keyword.get(opts, :interface, "wg0"),
      private_key: Keyword.fetch!(opts, :private_key),
      address: List.first(addresses),
      addresses: addresses,
      dns: Keyword.get(opts, :dns, []),
      peers: Keyword.get(opts, :peers, []),
      listen_port: Keyword.get(opts, :listen_port),
      fwmark: Keyword.get(opts, :fwmark),
      mtu: Keyword.get(opts, :mtu, @default_mtu),
      allow_userspace: Keyword.get(opts, :allow_userspace, false)
    }
  end

  @spec from_private_key(binary(), keyword()) :: t()
  def from_private_key(private_key, opts \\ []) when is_binary(private_key) do
    new(
      opts
      |> Keyword.put(:private_key, private_key)
      |> Keyword.put_new(:addresses, [@default_address])
      |> Keyword.put_new(:dns, @default_dns)
      |> Keyword.put_new(:mtu, @default_mtu)
    )
  end

  @spec from_file(binary(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_file(path, opts \\ []) when is_binary(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, attrs} <- parse_config(contents) do
      {:ok,
       new(
         opts
         |> Keyword.put(:private_key, Map.fetch!(attrs.interface, "privatekey"))
         |> Keyword.put(:addresses, Map.get(attrs.interface, "address", [@default_address]))
         |> Keyword.put(:dns, Map.get(attrs.interface, "dns", @default_dns))
         |> Keyword.put(:mtu, Map.get(attrs.interface, "mtu", @default_mtu))
         |> Keyword.put(:peers, build_peers(attrs.peer))
       )}
    end
  end

  @spec with_peer(t(), keyword()) :: t()
  def with_peer(%__MODULE__{} = config, opts) do
    peer = %{
      public_key: Keyword.fetch!(opts, :public_key),
      preshared_key: Keyword.get(opts, :preshared_key),
      endpoint: Keyword.fetch!(opts, :endpoint),
      allowed_ips: Keyword.get(opts, :allowed_ips, @default_allowed_ips),
      persistent_keepalive_interval:
        Keyword.get(opts, :persistent_keepalive_interval, @default_persistent_keepalive)
    }

    %__MODULE__{config | peers: [peer]}
  end

  @spec default_allowed_ips() :: [binary()]
  def default_allowed_ips, do: @default_allowed_ips

  @spec default_dns() :: [binary()]
  def default_dns, do: @default_dns

  @spec default_address() :: binary()
  def default_address, do: @default_address

  @spec default_persistent_keepalive() :: pos_integer()
  def default_persistent_keepalive, do: @default_persistent_keepalive

  defp parse_config(contents) do
    lines =
      contents
      |> String.split(~r/\r?\n/, trim: false)
      |> Enum.map(&String.trim/1)

    parse_lines(lines, %{interface: %{}, peer: %{}}, nil)
  end

  defp parse_lines([], %{interface: interface, peer: peer}, _section) do
    cond do
      blank?(Map.get(interface, "privatekey")) -> {:error, :private_key_missing}
      blank?(Map.get(peer, "publickey")) -> {:error, :peer_public_key_missing}
      blank?(Map.get(peer, "endpoint")) -> {:error, :peer_endpoint_missing}
      true -> {:ok, %{interface: interface, peer: peer}}
    end
  end

  defp parse_lines([line | rest], state, section) do
    cond do
      line == "" or String.starts_with?(line, "#") ->
        parse_lines(rest, state, section)

      String.starts_with?(line, "[") and String.ends_with?(line, "]") ->
        section =
          line
          |> String.trim_leading("[")
          |> String.trim_trailing("]")
          |> String.downcase()

        parse_lines(rest, state, section)

      true ->
        case String.split(line, "=", parts: 2) do
          [raw_key, raw_value] ->
            parse_lines(rest, put_config_value(state, section, raw_key, raw_value), section)

          _other ->
            parse_lines(rest, state, section)
        end
    end
  end

  defp put_config_value(state, "interface", raw_key, raw_value) do
    key = raw_key |> String.trim() |> String.downcase()
    value = String.trim(raw_value)

    interface_value =
      case key do
        "address" -> split_csv(value)
        "dns" -> split_csv(value)
        "mtu" -> parse_positive_integer(value, @default_mtu)
        _other -> value
      end

    put_in(state.interface[key], interface_value)
  end

  defp put_config_value(state, "peer", raw_key, raw_value) do
    key = raw_key |> String.trim() |> String.downcase()
    value = String.trim(raw_value)

    peer_value =
      case key do
        "allowedips" -> split_csv(value)
        "persistentkeepalive" -> parse_positive_integer(value, @default_persistent_keepalive)
        _other -> value
      end

    put_in(state.peer[key], peer_value)
  end

  defp put_config_value(state, _section, _raw_key, _raw_value), do: state

  defp build_peers(peer) do
    [
      %{
        public_key: Map.fetch!(peer, "publickey"),
        preshared_key: Map.get(peer, "presharedkey"),
        endpoint: Map.fetch!(peer, "endpoint"),
        allowed_ips: Map.get(peer, "allowedips", @default_allowed_ips),
        persistent_keepalive_interval:
          Map.get(peer, "persistentkeepalive", @default_persistent_keepalive)
      }
    ]
  end

  defp normalize_addresses([], nil), do: []
  defp normalize_addresses([], address) when is_binary(address), do: [address]
  defp normalize_addresses(addresses, _address), do: addresses

  defp split_csv(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&blank?/1)
  end

  defp parse_positive_integer(value, default) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp blank?(value), do: value in [nil, ""]
end
