defmodule ExUndercover.ProtonTest do
  use ExUnit.Case, async: true

  alias ExUndercover.Proton

  test "lists, filters, and deduplicates Proton endpoints" do
    snapshot_path =
      write_tmp("""
      {
        "fetched_at":"2026-04-20T00:00:00Z",
        "servers":[
          {"name":"NO-FREE#10","tier":0,"country":"NO","city":"Oslo","domain":"node-no-17.protonvpn.net","entry_ip":"95.173.205.161","exit_ip":"95.173.205.161","pubkey":"pub-no-10"},
          {"name":"NO-FREE#10","tier":0,"country":"NO","city":"Oslo","domain":"node-no-17.protonvpn.net","entry_ip":"95.173.205.161","exit_ip":"95.173.205.161","pubkey":"pub-no-10"},
          {"name":"NO-FREE#5","tier":0,"country":"NO","city":"Oslo","domain":"node-no-12.protonvpn.net","entry_ip":"95.173.205.167","exit_ip":"95.173.205.167","pubkey":"pub-no-5"},
          {"name":"NL-FREE#1","tier":0,"country":"NL","city":"Amsterdam","domain":"node-nl-01.protonvpn.net","entry_ip":"10.0.0.1","exit_ip":"10.0.0.1","pubkey":"pub-nl-1"}
        ]
      }
      """)

    assert {:ok, endpoints} =
             Proton.list_endpoints(snapshot_path: snapshot_path, country: "NO", tier: 0)

    assert Enum.map(endpoints, & &1.name) == ["NO-FREE#10", "NO-FREE#5"]
  end

  test "builds a Proton WireGuard config by combining conf credentials with a selected endpoint" do
    snapshot_path =
      write_tmp("""
      [
        {"name":"NO-FREE#10","tier":0,"country":"NO","city":"Oslo","domain":"node-no-17.protonvpn.net","entry_ip":"95.173.205.161","exit_ip":"95.173.205.161","pubkey":"pub-no-10"},
        {"name":"NL-FREE#1","tier":0,"country":"NL","city":"Amsterdam","domain":"node-nl-01.protonvpn.net","entry_ip":"10.0.0.1","exit_ip":"10.0.0.1","pubkey":"pub-nl-1"}
      ]
      """)

    conf_path =
      write_tmp("""
      [Interface]
      PrivateKey = priv-test
      Address = 10.2.0.2/32
      DNS = 10.2.0.1

      [Peer]
      PublicKey = stale-nl-pub
      AllowedIPs = 0.0.0.0/0, ::/0
      Endpoint = 185.132.133.79:51820
      PersistentKeepalive = 25
      """)

    assert {:ok, config} =
             Proton.build_wireguard_config(conf_path,
               snapshot_path: snapshot_path,
               country: "NO",
               tier: 0,
               name: "NO-FREE#10",
               interface: "wg-test"
             )

    assert config.interface == "wg-test"
    assert config.private_key == "priv-test"
    assert config.addresses == ["10.2.0.2/32"]
    assert config.dns == ["10.2.0.1"]
    assert [%{public_key: "pub-no-10", endpoint: "95.173.205.161:51820"}] = config.peers
  end

  defp write_tmp(contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ex_undercover_proton_#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, contents)
    path
  end
end
