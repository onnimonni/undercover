defmodule ExUndercover.Transport.ProfileSyncTest do
  use ExUnit.Case, async: true

  alias ExUndercover.Transport.ProfileSync

  test "resolves latest alias from the file store before falling back to native metadata" do
    assert {:ok, :chrome_147} = ProfileSync.latest_alias_target(:chrome_latest)
  end

  test "returns metadata exported by the native layer" do
    assert {:ok, metadata} = ProfileSync.metadata()
    assert is_map(metadata)
    assert is_map(metadata["latest_aliases"])
  end

  test "returns an error for unknown aliases when metadata has no match" do
    assert {:error, :unknown_alias} = ProfileSync.latest_alias_target(:missing_alias)
  end
end
