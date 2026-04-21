defmodule ExUndercover.Runtime do
  @moduledoc """
  Higher-level runtime bootstrap for the combined tunnel + routing stack.
  """

  alias ExUndercover.WireGuard

  @spec boot(keyword()) :: :ok | {:error, term()}
  def boot(opts) do
    wg_config = WireGuard.Config.new(Keyword.fetch!(opts, :wireguard))
    routing = Keyword.get(opts, :routing, [])
    interface_config = Keyword.get(opts, :interface_config, [])

    with :ok <- WireGuard.Manager.ensure_started(wg_config),
         :ok <- WireGuard.InterfaceConfig.configure(wg_config, interface_config),
         :ok <- maybe_apply_policy_routing(wg_config, routing) do
      :ok
    end
  end

  defp maybe_apply_policy_routing(_wg_config, []), do: :ok

  defp maybe_apply_policy_routing(%WireGuard.Config{} = wg_config, routing) do
    table = Keyword.fetch!(routing, :table)
    fwmark = Keyword.get(routing, :fwmark, wg_config.fwmark)
    runner = Keyword.get(routing, :runner, &WireGuard.PolicyRouting.run_command/2)

    WireGuard.PolicyRouting.route_all_traffic_through_table(
      wg_config.interface,
      table,
      fwmark: fwmark,
      gateway: Keyword.get(routing, :gateway),
      runner: runner
    )
  end
end
