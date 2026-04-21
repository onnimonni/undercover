defmodule ExUndercover do
  @moduledoc """
  Public entry points for the Elixir-side fauxbrowser replacement.

  Design:

  - kernel WireGuard is managed from Elixir through `Wireguardex`
  - browser impersonation lives in the Rust NIF transport
  - a real browser solver is launched only after anti-bot escalation
  """

  alias ExUndercover.BrowserProfile
  alias ExUndercover.CookieJar
  alias ExUndercover.Proton
  alias ExUndercover.Solver
  alias ExUndercover.Request
  alias ExUndercover.Response
  alias ExUndercover.Transport
  alias ExUndercover.WireGuard

  @spec request(Request.t() | String.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def request(request_or_url, opts \\ [])
  def request(%Request{} = request, opts), do: Transport.request(request, opts)

  def request(url, opts) when is_binary(url),
    do: url |> Request.new(opts) |> Transport.request(opts)

  @spec latest_profile() :: BrowserProfile.t()
  def latest_profile do
    ExUndercover.Profile.chrome_latest()
  end

  @spec clear_cookies(Request.t() | keyword()) :: :ok
  def clear_cookies(opts \\ [])

  def clear_cookies(%Request{} = request) do
    :ok = CookieJar.clear(CookieJar, request: request)
    Solver.Registry.reset(Solver.Registry, request: request)
  end

  def clear_cookies(opts) when is_list(opts) do
    solver_registry = Keyword.get(opts, :solver_registry, Solver.Registry)
    opts = Keyword.delete(opts, :solver_registry)
    :ok = CookieJar.clear(CookieJar, opts)
    Solver.Registry.reset(solver_registry, opts)
  end

  @spec open_tunnel(WireGuard.Config.t() | keyword()) :: :ok | {:error, term()}
  def open_tunnel(%WireGuard.Config{} = config) do
    WireGuard.Manager.ensure_started(config)
  end

  def open_tunnel(opts) do
    opts
    |> WireGuard.Config.new()
    |> WireGuard.Manager.ensure_started()
  end

  @spec proton_config(binary(), keyword()) :: {:ok, WireGuard.Config.t()} | {:error, term()}
  def proton_config(conf_path, opts \\ []) do
    Proton.build_wireguard_config(conf_path, opts)
  end

  @spec open_proton_tunnel(binary(), keyword()) :: :ok | {:error, term()}
  def open_proton_tunnel(conf_path, opts \\ []) do
    with {:ok, config} <- proton_config(conf_path, opts) do
      open_tunnel(config)
    end
  end
end
