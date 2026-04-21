defmodule ExUndercover.WireGuard.PolicyRouting do
  @moduledoc """
  Linux policy routing helper for kernel WireGuard setups.
  """

  @type runner :: (binary(), [binary()] -> {:ok, binary()} | {:error, term()})

  @spec route_all_traffic_through_table(binary(), non_neg_integer(), keyword()) ::
          :ok | {:error, term()}
  def route_all_traffic_through_table(interface, table, opts \\ []) do
    runner = Keyword.get(opts, :runner, &run_command/2)
    fwmark = Keyword.get(opts, :fwmark)
    gateway = Keyword.get(opts, :gateway)

    with :ok <-
           run(runner, "ip", [
             "route",
             "replace",
             "default",
             "dev",
             interface,
             "table",
             "#{table}"
           ]),
         :ok <- maybe_add_gateway_route(runner, gateway, interface, table),
         :ok <- maybe_add_fwmark_rule(runner, fwmark, table) do
      :ok
    end
  end

  @spec remove_policy(non_neg_integer(), keyword()) :: :ok | {:error, term()}
  def remove_policy(table, opts \\ []) do
    runner = Keyword.get(opts, :runner, &run_command/2)
    fwmark = Keyword.get(opts, :fwmark)

    with :ok <- maybe_delete_fwmark_rule(runner, fwmark, table),
         :ok <- run(runner, "ip", ["route", "flush", "table", "#{table}"]) do
      :ok
    end
  end

  @spec run_command(binary(), [binary()]) :: {:ok, binary()} | {:error, term()}
  def run_command(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:exit_status, status, output}}
    end
  rescue
    error -> {:error, error}
  end

  defp maybe_add_gateway_route(_runner, nil, _interface, _table), do: :ok

  defp maybe_add_gateway_route(runner, gateway, interface, table) do
    run(runner, "ip", [
      "route",
      "replace",
      gateway,
      "dev",
      interface,
      "table",
      "#{table}"
    ])
  end

  defp maybe_add_fwmark_rule(_runner, nil, _table), do: :ok

  defp maybe_add_fwmark_rule(runner, fwmark, table) do
    run(runner, "ip", ["rule", "replace", "fwmark", "#{fwmark}", "lookup", "#{table}"])
  end

  defp maybe_delete_fwmark_rule(_runner, nil, _table), do: :ok

  defp maybe_delete_fwmark_rule(runner, fwmark, table) do
    case run(runner, "ip", ["rule", "del", "fwmark", "#{fwmark}", "lookup", "#{table}"]) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end

  defp run(runner, command, args) do
    case runner.(command, args) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {command, args, reason}}
    end
  end
end
