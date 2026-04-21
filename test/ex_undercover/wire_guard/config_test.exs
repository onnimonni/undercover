defmodule ExUndercover.WireGuard.ConfigTest do
  use ExUnit.Case, async: true

  alias ExUndercover.WireGuard.Config

  test "applies defaults" do
    config = Config.new(private_key: "private-key")

    assert config.interface == "wg0"
    assert config.private_key == "private-key"
    assert config.dns == []
    assert config.peers == []
  end

  test "keeps explicit settings" do
    config =
      Config.new(
        interface: "wg-test",
        private_key: "private-key",
        fwmark: 42,
        peers: [%{public_key: "pub", endpoint: "1.2.3.4:51820"}]
      )

    assert config.interface == "wg-test"
    assert config.fwmark == 42
    assert [%{endpoint: "1.2.3.4:51820"}] = config.peers
  end
end
