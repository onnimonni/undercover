defmodule ExUndercover.ProfileRegistryTest do
  use ExUnit.Case, async: false

  test "loads known profiles into registry state" do
    state = :sys.get_state(ExUndercover.ProfileRegistry)

    assert %{profiles: profiles} = state
    assert profiles.chrome_latest.id == :chrome_147
    assert profiles.chrome_147.id == :chrome_147
  end
end
