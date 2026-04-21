defmodule ExUndercover.WireGuardTest do
  use ExUnit.Case, async: true

  alias ExUndercover.WireGuard.Config
  alias ExUndercover.WireGuard.InterfaceConfig
  alias ExUndercover.WireGuard.Manager

  test "builds device and peer configs for wireguardex" do
    config =
      Config.new(
        interface: "wg-test",
        private_key: "priv-test",
        listen_port: 51820,
        fwmark: 1234,
        peers: [
          %{
            public_key: "pub-test",
            preshared_key: "psk-test",
            endpoint: "95.173.205.161:51820",
            allowed_ips: ["0.0.0.0/0", "::/0"],
            persistent_keepalive_interval: 25
          }
        ]
      )

    assert %Wireguardex.DeviceConfig{
             private_key: "priv-test",
             listen_port: 51820,
             fwmark: 1234
           } = Manager.device_config(config)

    assert [
             %Wireguardex.PeerConfig{
               public_key: "pub-test",
               preshared_key: "psk-test",
               endpoint: "95.173.205.161:51820",
               allowed_ips: ["0.0.0.0/0", "::/0"],
               persistent_keepalive_interval: 25
             }
           ] = Manager.peer_configs(config)
  end

  test "builds linux interface commands from WireGuard config" do
    config =
      Config.new(
        interface: "wg-test",
        private_key: "priv-test",
        addresses: ["10.2.0.2/32", "fd00::2/128"],
        mtu: 1420
      )

    parent = self()

    runner = fn args, opts ->
      send(parent, {:wireguard_cmd, args, opts})
      :ok
    end

    assert :ok = InterfaceConfig.configure(config, runner: runner, os: {:unix, :linux})

    assert_receive {:wireguard_cmd, ["address", "replace", "10.2.0.2/32", "dev", "wg-test"],
                    [executable: "ip"]}

    assert_receive {:wireguard_cmd, ["address", "replace", "fd00::2/128", "dev", "wg-test"],
                    [executable: "ip"]}

    assert_receive {:wireguard_cmd, ["link", "set", "mtu", "1420", "dev", "wg-test"],
                    [executable: "ip"]}

    assert_receive {:wireguard_cmd, ["link", "set", "up", "dev", "wg-test"], [executable: "ip"]}
  end

  test "rejects userspace fallback by default on non-linux hosts" do
    config =
      Config.new(
        interface: "wg-test",
        private_key: "priv-test",
        peers: [%{public_key: "pub-test", endpoint: "95.173.205.161:51820"}]
      )

    case :os.type() do
      {:unix, :linux} ->
        assert true

      {_family, _os} ->
        assert {:error, {:userspace_wireguard_disabled, _details}} =
                 Manager.ensure_started(config)
    end
  end
end
