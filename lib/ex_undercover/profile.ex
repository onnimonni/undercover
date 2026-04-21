defmodule ExUndercover.Profile do
  @moduledoc """
  Versioned browser profile registry.

  `chrome_latest/0` intentionally resolves to an exact versioned profile rather
  than a mutable blob in the transport layer.
  """

  alias ExUndercover.BrowserProfile
  alias ExUndercover.Profile.Chrome147
  alias ExUndercover.Profile.Store

  @spec chrome_latest() :: BrowserProfile.t()
  def chrome_latest do
    case Store.resolve_alias(:chrome_latest) do
      nil -> Chrome147.profile()
      target -> resolve(target)
    end
  end

  @spec resolve(atom() | BrowserProfile.t()) :: BrowserProfile.t()
  def resolve(%BrowserProfile{} = profile), do: profile
  def resolve(:chrome_latest), do: chrome_latest()

  def resolve(profile_id) when is_atom(profile_id) do
    profile_id
    |> Atom.to_string()
    |> resolve_binary()
  end

  def resolve(profile_id) when is_binary(profile_id) do
    resolve_binary(profile_id)
  end

  @spec known_profiles() :: [atom()]
  def known_profiles do
    profiles =
      Store.list()
      |> Kernel.++([:chrome_147])
      |> Enum.uniq()

    case Store.resolve_alias(:chrome_latest) do
      nil -> profiles
      latest -> Enum.uniq([:chrome_latest, latest | profiles])
    end
  end

  @spec to_transport_map(BrowserProfile.t()) :: map()
  def to_transport_map(%BrowserProfile{} = profile) do
    profile_map = BrowserProfile.to_map(profile)
    transport = Map.fetch!(profile_map, "transport")

    profile_map
    |> Map.delete("transport")
    |> Map.put("tls", Map.fetch!(transport, "tls"))
    |> Map.put("http2", Map.fetch!(transport, "http2"))
  end

  defp resolve_binary("chrome_latest"), do: chrome_latest()

  defp resolve_binary(profile_id) do
    case Store.load(profile_id) do
      {:ok, profile} ->
        profile

      {:error, :enoent} ->
        resolve_builtin(profile_id)

      {:error, reason} ->
        raise ArgumentError,
              "failed to load browser profile #{inspect(profile_id)}: #{inspect(reason)}"
    end
  end

  defp resolve_builtin("chrome_147"), do: Chrome147.profile()

  defp resolve_builtin(other),
    do: raise(ArgumentError, "unknown browser profile: #{inspect(other)}")
end
