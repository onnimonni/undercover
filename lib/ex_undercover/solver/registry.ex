defmodule ExUndercover.Solver.Registry do
  @moduledoc """
  Coordinates real-browser solver work.

  The registry exists to avoid launching a browser per challenged request:

  - one in-flight solve per `(host, WireGuard bucket, profile, backend)`
  - bounded global concurrency
  - bounded queue with backpressure
  - per-key circuit breaker for repeated retry failures
  """

  use GenServer

  alias ExUndercover.CookieJar
  alias ExUndercover.Request

  @default_max_concurrency 4
  @default_max_queue 256
  @default_circuit_threshold 3
  @default_circuit_open_ms :timer.minutes(10)
  @default_call_timeout :timer.seconds(90)

  @type request_key :: binary()

  @type circuit_status :: %{
          consecutive_failures: non_neg_integer(),
          open?: boolean(),
          opened_until_ms: integer() | nil
        }

  defstruct max_concurrency: @default_max_concurrency,
            max_queue: @default_max_queue,
            circuit_threshold: @default_circuit_threshold,
            circuit_open_ms: @default_circuit_open_ms,
            active_count: 0,
            queue: :queue.new(),
            jobs: %{},
            task_refs: %{},
            circuits: %{},
            completed: %{}

  @type state :: %__MODULE__{
          max_concurrency: pos_integer(),
          max_queue: pos_integer(),
          circuit_threshold: pos_integer(),
          circuit_open_ms: pos_integer(),
          active_count: non_neg_integer(),
          queue: :queue.queue(request_key()),
          jobs: %{optional(request_key()) => map()},
          task_refs: %{optional(reference()) => request_key()},
          circuits: %{optional(request_key()) => map()},
          completed: %{optional(request_key()) => map()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec lookup_or_solve(pid() | atom(), Request.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def lookup_or_solve(server \\ __MODULE__, %Request{} = request, opts \\ []) do
    timeout = Keyword.get(opts, :solver_registry_timeout, @default_call_timeout)
    GenServer.call(server, {:lookup_or_solve, request, opts}, timeout)
  end

  @spec circuit_open?(pid() | atom(), Request.t(), keyword()) :: boolean()
  def circuit_open?(server \\ __MODULE__, %Request{} = request, opts \\ []) do
    GenServer.call(server, {:circuit_open?, request_key(request, opts)})
  end

  @spec mark_retry_failed(pid() | atom(), Request.t(), keyword()) :: circuit_status()
  def mark_retry_failed(server \\ __MODULE__, %Request{} = request, opts \\ []) do
    GenServer.call(server, {:mark_retry_failed, request_key(request, opts)})
  end

  @spec mark_retry_succeeded(pid() | atom(), Request.t(), keyword()) :: :ok
  def mark_retry_succeeded(server \\ __MODULE__, %Request{} = request, opts \\ []) do
    GenServer.call(server, {:mark_retry_succeeded, request_key(request, opts)})
  end

  @spec reset(pid() | atom(), keyword()) :: :ok
  def reset(server \\ __MODULE__, opts \\ []) when is_list(opts) do
    GenServer.call(server, {:reset, opts})
  end

  @spec stats(pid() | atom()) :: map()
  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats)
  end

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       max_concurrency: Keyword.get(opts, :max_concurrency, @default_max_concurrency),
       max_queue: Keyword.get(opts, :max_queue, @default_max_queue),
       circuit_threshold: Keyword.get(opts, :circuit_threshold, @default_circuit_threshold),
       circuit_open_ms: Keyword.get(opts, :circuit_open_ms, @default_circuit_open_ms)
     }}
  end

  @impl true
  def handle_call({:lookup_or_solve, request, opts}, from, %__MODULE__{} = state) do
    key = request_key(request, opts)
    state = expire_circuit(state, key)

    cond do
      circuit_open_state?(state, key) ->
        {:reply, {:error, {:solver_circuit_open, circuit_status(state, key)}}, state}

      Map.has_key?(state.jobs, key) ->
        {:noreply, update_waiters(state, key, &[from | &1])}

      state.active_count < state.max_concurrency ->
        {:noreply, start_job(state, key, request, opts, [from])}

      queue_length(state.queue) >= state.max_queue ->
        {:reply, {:error, :solver_queue_full}, state}

      true ->
        {:noreply, enqueue_job(state, key, request, opts, [from])}
    end
  end

  def handle_call({:circuit_open?, key}, _from, %__MODULE__{} = state) do
    state = expire_circuit(state, key)
    {:reply, circuit_open_state?(state, key), state}
  end

  def handle_call({:mark_retry_failed, key}, _from, %__MODULE__{} = state) do
    state = expire_circuit(state, key)
    {state, status} = open_or_increment_circuit(state, key)
    {:reply, status, state}
  end

  def handle_call({:mark_retry_succeeded, key}, _from, %__MODULE__{} = state) do
    {:reply, :ok, clear_circuit(state, key)}
  end

  def handle_call({:reset, opts}, _from, %__MODULE__{} = state) do
    {:reply, :ok, reset_scope(state, opts)}
  end

  def handle_call(:stats, _from, %__MODULE__{} = state) do
    {:reply,
     %{
       active_count: state.active_count,
       queued_count: queue_length(state.queue),
       inflight_keys: Map.keys(state.jobs),
       circuits:
         Map.new(state.circuits, fn {key, _entry} -> {key, circuit_status(state, key)} end),
       completed: state.completed
     }, state}
  end

  @impl true
  def handle_info({ref, result}, %__MODULE__{} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case pop_running_job(state, ref) do
      {:ok, job, %__MODULE__{} = state} ->
        Enum.each(job.waiters, &GenServer.reply(&1, result))

        completed =
          Map.put(state.completed, job.key, %{
            finished_at: DateTime.utc_now(),
            status: normalize_result_status(result),
            waiters: length(job.waiters),
            target_url: job.request.url
          })

        {:noreply, %__MODULE__{state | completed: completed} |> drain_queue()}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %__MODULE__{} = state)
      when is_reference(ref) do
    case pop_running_job(state, ref) do
      {:ok, job, state} ->
        Enum.each(job.waiters, &GenServer.reply(&1, {:error, {:solver_crashed, reason}}))
        {:noreply, drain_queue(state)}

      :error ->
        {:noreply, state}
    end
  end

  defp start_job(%__MODULE__{} = state, key, %Request{} = request, opts, waiters) do
    task =
      Task.Supervisor.async_nolink(ExUndercover.Solver.TaskSupervisor, fn ->
        backend = Keyword.get(opts, :backend, ExUndercover.Solver.Chrome)
        backend.solve(request.url, opts)
      end)

    job = %{
      key: key,
      request: request,
      opts: opts,
      waiters: waiters,
      status: :running,
      task_ref: task.ref
    }

    %__MODULE__{
      state
      | active_count: state.active_count + 1,
        jobs: Map.put(state.jobs, key, job),
        task_refs: Map.put(state.task_refs, task.ref, key)
    }
  end

  defp enqueue_job(%__MODULE__{} = state, key, %Request{} = request, opts, waiters) do
    job = %{key: key, request: request, opts: opts, waiters: waiters, status: :queued}

    %__MODULE__{
      state
      | jobs: Map.put(state.jobs, key, job),
        queue: :queue.in(key, state.queue)
    }
  end

  defp update_waiters(%__MODULE__{} = state, key, fun) do
    update_in(state.jobs[key].waiters, fun)
  end

  defp pop_running_job(%__MODULE__{} = state, ref) do
    with {:ok, key} <- Map.fetch(state.task_refs, ref),
         {:ok, job} <- Map.fetch(state.jobs, key) do
      state = %__MODULE__{
        state
        | active_count: max(state.active_count - 1, 0),
          jobs: Map.delete(state.jobs, key),
          task_refs: Map.delete(state.task_refs, ref)
      }

      {:ok, job, state}
    else
      _ -> :error
    end
  end

  defp drain_queue(%__MODULE__{} = state) do
    if state.active_count >= state.max_concurrency do
      state
    else
      state
      |> dequeue_next_job()
      |> case do
        {:ok, state, key, job} ->
          state
          |> start_job(key, job.request, job.opts, Enum.reverse(job.waiters))
          |> drain_queue()

        :empty ->
          state
      end
    end
  end

  defp dequeue_next_job(%__MODULE__{} = state) do
    case :queue.out(state.queue) do
      {{:value, key}, queue} ->
        state = %__MODULE__{state | queue: queue}

        case Map.fetch(state.jobs, key) do
          {:ok, %{status: :queued} = job} ->
            {:ok, %__MODULE__{state | jobs: Map.delete(state.jobs, key)}, key, job}

          _other ->
            dequeue_next_job(state)
        end

      {:empty, _queue} ->
        :empty
    end
  end

  defp request_key(%Request{} = request, opts) do
    backend =
      opts
      |> Keyword.get(:backend, ExUndercover.Solver.Chrome)
      |> inspect()

    host =
      case URI.parse(request.url) do
        %URI{host: host} when is_binary(host) -> String.downcase(host)
        _ -> "unknown"
      end

    profile =
      request.browser_profile
      |> to_string()

    [host, CookieJar.bucket_for(request), profile, backend]
    |> Enum.join("|")
  end

  defp expire_circuit(%__MODULE__{} = state, key) do
    now_ms = System.monotonic_time(:millisecond)

    case Map.get(state.circuits, key) do
      %{opened_until_ms: opened_until_ms} = circuit
      when is_integer(opened_until_ms) and opened_until_ms <= now_ms ->
        put_in(state.circuits[key], %{circuit | consecutive_failures: 0, opened_until_ms: nil})

      _other ->
        state
    end
  end

  defp circuit_open_state?(%__MODULE__{} = state, key) do
    match?(
      %{opened_until_ms: opened_until_ms} when is_integer(opened_until_ms),
      Map.get(state.circuits, key)
    )
  end

  defp open_or_increment_circuit(%__MODULE__{} = state, key) do
    current = Map.get(state.circuits, key, %{consecutive_failures: 0, opened_until_ms: nil})
    consecutive_failures = current.consecutive_failures + 1

    opened_until_ms =
      if consecutive_failures >= state.circuit_threshold do
        System.monotonic_time(:millisecond) + state.circuit_open_ms
      else
        current.opened_until_ms
      end

    circuit = %{consecutive_failures: consecutive_failures, opened_until_ms: opened_until_ms}
    state = put_in(state.circuits[key], circuit)
    {state, circuit_status(state, key)}
  end

  defp clear_circuit(%__MODULE__{} = state, key) do
    update_in(state.circuits, &Map.delete(&1, key))
  end

  defp circuit_status(%__MODULE__{} = state, key) do
    state = expire_circuit(state, key)

    case Map.get(state.circuits, key) do
      %{consecutive_failures: failures, opened_until_ms: opened_until_ms} ->
        %{
          consecutive_failures: failures,
          open?: is_integer(opened_until_ms),
          opened_until_ms: opened_until_ms
        }

      nil ->
        %{
          consecutive_failures: 0,
          open?: false,
          opened_until_ms: nil
        }
    end
  end

  defp reset_scope(%__MODULE__{} = state, opts) do
    bucket = clear_bucket(opts)
    host = clear_host(opts)

    keys_to_clear =
      state.circuits
      |> Map.keys()
      |> Enum.filter(fn key ->
        matches_bucket?(key, bucket) and matches_host?(key, host)
      end)

    Enum.reduce(keys_to_clear, state, &clear_circuit(&2, &1))
  end

  defp clear_bucket(opts) do
    case Keyword.get(opts, :request) do
      %Request{} = request ->
        CookieJar.bucket_for(request)

      _other ->
        case Keyword.get(opts, :wireguard_ip_address, Keyword.get(opts, :bucket)) do
          value when is_binary(value) and value != "" -> value
          _ -> nil
        end
    end
  end

  defp clear_host(opts) do
    case Keyword.get(opts, :request) do
      %Request{} = request ->
        request.url |> URI.parse() |> Map.get(:host) |> normalize_host()

      _other ->
        case Keyword.get(opts, :host) do
          value when is_binary(value) and value != "" -> normalize_host(value)
          _ -> nil
        end
    end
  end

  defp matches_bucket?(_key, nil), do: true

  defp matches_bucket?(key, bucket) do
    [_host, key_bucket | _rest] = String.split(key, "|")
    key_bucket == bucket
  end

  defp matches_host?(_key, nil), do: true

  defp matches_host?(key, host) do
    [key_host | _rest] = String.split(key, "|")
    key_host == host
  end

  defp normalize_host(nil), do: nil
  defp normalize_host(host), do: host |> to_string() |> String.downcase()

  defp queue_length(queue), do: :queue.len(queue)

  defp normalize_result_status({:ok, _result}), do: :ok
  defp normalize_result_status({:error, reason}), do: {:error, reason}
  defp normalize_result_status(other), do: {:unexpected, other}
end
