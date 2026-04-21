defmodule ExUndercover.ProfileRegistry do
  use GenServer

  alias ExUndercover.Profile
  alias ExUndercover.Transport.ProfileSync

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    latest_profile =
      case ProfileSync.latest_alias_target(:chrome_latest) do
        {:ok, target} -> Profile.resolve(target)
        _ -> Profile.chrome_latest()
      end

    profiles =
      Profile.known_profiles()
      |> Enum.reject(&(&1 == :chrome_latest))
      |> Enum.reduce(%{chrome_latest: latest_profile}, fn profile_id, acc ->
        Map.put(acc, profile_id, Profile.resolve(profile_id))
      end)

    {:ok, Map.put(state, :profiles, profiles)}
  end
end
