defmodule ExUndercover.WireGuard.PolicyRoutingTest do
  use ExUnit.Case, async: true

  alias ExUndercover.WireGuard.PolicyRouting

  test "builds route and fwmark commands" do
    parent = self()

    runner = fn command, args ->
      send(parent, {:runner, command, args})
      {:ok, "ok"}
    end

    assert :ok =
             PolicyRouting.route_all_traffic_through_table("wg0", 100,
               fwmark: 42,
               gateway: "10.0.0.1",
               runner: runner
             )

    assert_received {:runner, "ip", ["route", "replace", "default", "dev", "wg0", "table", "100"]}

    assert_received {:runner, "ip",
                     ["route", "replace", "10.0.0.1", "dev", "wg0", "table", "100"]}

    assert_received {:runner, "ip", ["rule", "replace", "fwmark", "42", "lookup", "100"]}
  end

  test "remove_policy tolerates missing fwmark rules and flushes the table" do
    parent = self()

    runner = fn
      "ip", ["rule", "del", "fwmark", "42", "lookup", "100"] ->
        send(parent, {:runner, "ip", ["rule", "del", "fwmark", "42", "lookup", "100"]})
        {:error, :enoent}

      command, args ->
        send(parent, {:runner, command, args})
        {:ok, "ok"}
    end

    assert :ok = PolicyRouting.remove_policy(100, fwmark: 42, runner: runner)
    assert_received {:runner, "ip", ["rule", "del", "fwmark", "42", "lookup", "100"]}
    assert_received {:runner, "ip", ["route", "flush", "table", "100"]}
  end

  test "returns detailed errors from the runner" do
    runner = fn "ip", ["route", "replace", "default", "dev", "wg0", "table", "100"] ->
      {:error, :eperm}
    end

    assert {:error, {"ip", ["route", "replace", "default", "dev", "wg0", "table", "100"], :eperm}} =
             PolicyRouting.route_all_traffic_through_table("wg0", 100, runner: runner)
  end

  test "skips optional gateway and fwmark commands when not configured" do
    parent = self()

    runner = fn command, args ->
      send(parent, {:runner, command, args})
      {:ok, "ok"}
    end

    assert :ok = PolicyRouting.route_all_traffic_through_table("wg0", 100, runner: runner)

    assert_received {:runner, "ip", ["route", "replace", "default", "dev", "wg0", "table", "100"]}

    refute_received {:runner, "ip", ["rule", "replace", "fwmark", _, "lookup", _]}
  end

  test "run_command reports command failures" do
    assert {:error, _reason} = PolicyRouting.run_command("definitely-missing-command", [])
  end
end
