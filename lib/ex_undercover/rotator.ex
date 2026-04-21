defmodule ExUndercover.Rotator do
  @moduledoc """
  Host-level rotation coordinator.

  This module is the Elixir-side replacement boundary for fauxbrowser's rotation
  heuristics. It does not swap WireGuard peers yet, but it already models the
  public contract:

  - record host-specific rate-limit or challenge events
  - debounce repeated rotations for the same host
  - expose recent events for diagnostics
  """

  use GenServer

  @default_host_debounce_ms :timer.minutes(5)
  @recent_limit 50

  @type event :: %{
          host: binary(),
          reason: binary(),
          classification: atom(),
          at: DateTime.t()
        }

  defstruct host_debounce_ms: @default_host_debounce_ms,
            hosts: %{},
            recent: []

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec notify(pid() | atom(), binary(), atom(), map()) :: :ok
  def notify(server \\ __MODULE__, host, classification, details) do
    GenServer.cast(server, {:notify, host, classification, details})
  end

  @spec should_rotate?(pid() | atom(), binary()) :: boolean()
  def should_rotate?(server \\ __MODULE__, host) do
    GenServer.call(server, {:should_rotate?, host})
  end

  @spec recent(pid() | atom()) :: [event()]
  def recent(server \\ __MODULE__) do
    GenServer.call(server, :recent)
  end

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       host_debounce_ms: Keyword.get(opts, :host_debounce_ms, @default_host_debounce_ms)
     }}
  end

  @impl true
  def handle_call({:should_rotate?, host}, _from, %__MODULE__{} = state) do
    now_ms = System.monotonic_time(:millisecond)

    allowed? =
      case state.hosts do
        %{^host => %{last_rotation_ms: last_ms}} -> now_ms - last_ms >= state.host_debounce_ms
        _ -> true
      end

    {:reply, allowed?, state}
  end

  def handle_call(:recent, _from, %__MODULE__{} = state) do
    {:reply, state.recent, state}
  end

  @impl true
  def handle_cast({:notify, host, classification, details}, %__MODULE__{} = state) do
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    reason =
      details
      |> Map.get(:reason, Map.get(details, "reason", "unknown"))
      |> to_string()

    recent = [
      %{host: host, reason: reason, classification: classification, at: now}
      | Enum.take(state.recent, @recent_limit - 1)
    ]

    hosts =
      case classification do
        classification when classification in [:rate_limited, :challenge] ->
          Map.put(state.hosts, host, %{last_rotation_ms: now_ms, last_reason: reason})

        _ ->
          state.hosts
      end

    {:noreply, %__MODULE__{state | hosts: hosts, recent: recent}}
  end
end
