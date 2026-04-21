defmodule ExUndercover.Profile.Store do
  @moduledoc """
  File-backed browser profile store.

  Profiles live in `priv/profiles/*.json`. Alias mappings live in
  `priv/profiles/aliases.json`.
  """

  alias ExUndercover.BrowserProfile

  @spec aliases() :: map()
  def aliases do
    read_json(aliases_path(), %{})
  end

  @spec resolve_alias(atom() | binary()) :: atom() | nil
  def resolve_alias(name) when is_atom(name), do: resolve_alias(Atom.to_string(name))

  def resolve_alias(name) when is_binary(name) do
    case Map.get(aliases(), name) do
      nil -> nil
      target -> String.to_atom(target)
    end
  end

  @spec list() :: [atom()]
  def list do
    profiles_dir()
    |> File.ls!()
    |> Enum.reject(&(&1 == "aliases.json"))
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.map(&String.replace_suffix(&1, ".json", ""))
    |> Enum.map(&String.to_atom/1)
    |> Enum.sort()
  end

  @spec load(atom() | binary()) :: {:ok, BrowserProfile.t()} | {:error, term()}
  def load(id) when is_atom(id), do: load(Atom.to_string(id))

  def load(id) when is_binary(id) do
    path = profile_path(id)

    with true <- File.exists?(path) || {:error, :enoent},
         {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, BrowserProfile.from_map(decoded)}
    else
      false -> {:error, :enoent}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec write_profile!(BrowserProfile.t() | map()) :: :ok
  def write_profile!(%BrowserProfile{} = profile) do
    write_json!(profile_path(profile.id), BrowserProfile.to_map(profile))
  end

  def write_profile!(%{} = profile_map) do
    profile_map
    |> BrowserProfile.from_map()
    |> write_profile!()
  end

  @spec write_aliases!(map()) :: :ok
  def write_aliases!(aliases) when is_map(aliases) do
    normalized =
      Map.new(aliases, fn {key, value} ->
        {to_string(key), to_string(value)}
      end)

    write_json!(aliases_path(), normalized)
  end

  @spec profile_path(atom() | binary()) :: binary()
  def profile_path(id) when is_atom(id), do: profile_path(Atom.to_string(id))
  def profile_path(id) when is_binary(id), do: Path.join(profiles_dir(), "#{id}.json")

  @spec profiles_dir() :: binary()
  def profiles_dir do
    Application.app_dir(:ex_undercover, "priv/profiles")
  end

  @spec aliases_path() :: binary()
  def aliases_path do
    Path.join(profiles_dir(), "aliases.json")
  end

  defp read_json(path, fallback) do
    with true <- File.exists?(path),
         {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      decoded
    else
      _ -> fallback
    end
  end

  defp write_json!(path, data) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode_to_iodata!(data, pretty: true))
  end
end
