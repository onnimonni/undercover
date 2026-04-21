defmodule ExUndercover.WireGuard.InterfaceConfig do
  @moduledoc """
  OS-level interface address and link-state configuration.

  `wireguardex` applies the WireGuard peer/device configuration, but the
  interface still needs IP addresses and link state configured by the OS.
  """

  alias ExUndercover.WireGuard.Config

  @spec configure(Config.t(), keyword()) :: :ok | {:error, term()}
  def configure(%Config{} = cfg, opts \\ []) do
    runner = Keyword.get(opts, :runner, &run_command/2)
    os = Keyword.get(opts, :os, :os.type())

    case os do
      {:unix, :linux} ->
        linux_configure(cfg, runner)

      {family, os} ->
        {:error, {:unsupported_interface_configuration, %{os_family: family, os: os}}}
    end
  end

  @spec run_command([binary()], keyword()) :: :ok | {:error, term()}
  def run_command(args, opts \\ []) when is_list(args) do
    executable = Keyword.get(opts, :executable, "ip")
    env = Keyword.get(opts, :env, [])

    case System.cmd(executable, args, stderr_to_stdout: true, env: env) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:command_failed, executable, args, status, output}}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp linux_configure(%Config{} = cfg, runner) do
    commands =
      Enum.map(cfg.addresses, fn address ->
        ["address", "replace", address, "dev", cfg.interface]
      end) ++
        [
          ["link", "set", "mtu", Integer.to_string(cfg.mtu), "dev", cfg.interface],
          ["link", "set", "up", "dev", cfg.interface]
        ]

    Enum.reduce_while(commands, :ok, fn args, :ok ->
      case runner.(args, executable: "ip") do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
