defmodule ExUndercover.BrowserProfile do
  @enforce_keys [:id, :browser, :version, :platform, :headers]
  defstruct id: nil,
            browser: :chrome,
            version: nil,
            platform: :linux,
            headers: [],
            transport: %{tls: %{}, http2: %{}}

  @type t :: %__MODULE__{
          id: atom(),
          browser: atom(),
          version: String.t(),
          platform: atom(),
          headers: [{binary(), binary()}],
          transport: %{optional(atom()) => map()}
        }

  @spec from_map(map()) :: t()
  def from_map(%{} = map) do
    %__MODULE__{
      id: map |> fetch!("id") |> to_atom(),
      browser: map |> fetch!("browser") |> to_atom(),
      version: fetch!(map, "version"),
      platform: map |> fetch!("platform") |> to_atom(),
      headers: map |> fetch!("headers") |> normalize_headers(),
      transport: fetch!(map, "transport")
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = profile) do
    %{
      "id" => Atom.to_string(profile.id),
      "browser" => Atom.to_string(profile.browser),
      "version" => profile.version,
      "platform" => Atom.to_string(profile.platform),
      "headers" => Enum.map(profile.headers, fn {name, value} -> [name, value] end),
      "transport" => stringify_keys(profile.transport)
    }
  end

  defp fetch!(map, key) when is_binary(key) do
    Map.get(map, key) || Map.fetch!(map, String.to_atom(key))
  end

  defp normalize_headers(headers) do
    Enum.map(headers, fn
      [name, value] -> {name, value}
      {name, value} -> {name, value}
    end)
  end

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), stringify_keys(value)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp to_atom(value) when is_atom(value), do: value
  defp to_atom(value) when is_binary(value), do: String.to_atom(value)
end
