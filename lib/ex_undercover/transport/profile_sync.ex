defmodule ExUndercover.Transport.ProfileSync do
  @moduledoc """
  Synchronizes Elixir-side profile aliases with metadata exported by the Rust
  transport.
  """

  alias ExUndercover.Nif
  alias ExUndercover.Profile.Store

  @spec metadata() :: {:ok, map()} | {:error, term()}
  def metadata do
    Nif.profile_metadata()
  end

  @spec latest_alias_target(atom()) :: {:ok, atom()} | {:error, term()}
  def latest_alias_target(alias_name) when is_atom(alias_name) do
    case Store.resolve_alias(alias_name) do
      target when is_atom(target) and not is_nil(target) ->
        {:ok, target}

      nil ->
        fallback_latest_alias_target(alias_name)
    end
  end

  defp fallback_latest_alias_target(alias_name) do
    with {:ok, %{"latest_aliases" => aliases}} <- metadata(),
         target when is_binary(target) <- Map.get(aliases, Atom.to_string(alias_name)) do
      {:ok, String.to_atom(target)}
    else
      nil -> {:error, :unknown_alias}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_metadata, other}}
    end
  end
end
