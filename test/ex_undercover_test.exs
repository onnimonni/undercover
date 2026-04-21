defmodule ExUndercoverTest do
  use ExUnit.Case, async: true

  test "latest_profile returns the resolved chrome profile" do
    assert ExUndercover.latest_profile().id == :chrome_147
  end
end
