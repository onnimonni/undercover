defmodule ExUndercover.SolverRegistryTest do
  use ExUnit.Case, async: false

  alias ExUndercover.Request
  alias ExUndercover.Solver.Registry
  alias ExUndercover.TestSupport.CountingSolver

  defmodule CrashingSolver do
    @behaviour ExUndercover.Solver

    @impl true
    def solve(_url, _opts) do
      raise "solver crashed"
    end
  end

  test "returns queue full when distinct solver jobs exceed capacity" do
    test_pid = self()

    start_supervised!(
      {Registry,
       name: :queue_solver_registry, max_concurrency: 1, max_queue: 1, circuit_threshold: 2}
    )

    request_a =
      Request.new("https://a.example.test/challenge",
        metadata: %{"wireguard_ip_address" => "10.0.0.2"}
      )

    request_b =
      Request.new("https://b.example.test/challenge",
        metadata: %{"wireguard_ip_address" => "10.0.0.2"}
      )

    request_c =
      Request.new("https://c.example.test/challenge",
        metadata: %{"wireguard_ip_address" => "10.0.0.2"}
      )

    task_a =
      Task.async(fn ->
        Registry.lookup_or_solve(:queue_solver_registry, request_a,
          backend: CountingSolver,
          notify_pid: test_pid,
          solver_delay_ms: 250
        )
      end)

    assert_receive {:solver_called, "https://a.example.test/challenge", _}, 1_000

    task_b =
      Task.async(fn ->
        Registry.lookup_or_solve(:queue_solver_registry, request_b,
          backend: CountingSolver,
          notify_pid: test_pid,
          solver_delay_ms: 10
        )
      end)

    wait_until(fn ->
      Registry.stats(:queue_solver_registry).queued_count == 1
    end)

    assert {:error, :solver_queue_full} =
             Registry.lookup_or_solve(:queue_solver_registry, request_c,
               backend: CountingSolver,
               notify_pid: test_pid
             )

    assert {:ok, _result} = Task.await(task_a, 2_000)
    assert {:ok, _result} = Task.await(task_b, 2_000)
    assert_receive {:solver_called, "https://b.example.test/challenge", _}, 1_000
  end

  test "reset clears circuit state for the matching request scope" do
    start_supervised!(
      {Registry,
       name: :reset_solver_registry,
       max_concurrency: 1,
       max_queue: 1,
       circuit_threshold: 2,
       circuit_open_ms: 5_000}
    )

    request =
      Request.new("https://www.example.test/challenge",
        metadata: %{"wireguard_ip_address" => "10.0.0.2"}
      )

    assert %{open?: false} =
             Registry.mark_retry_failed(:reset_solver_registry, request, backend: CountingSolver)

    assert %{open?: true} =
             Registry.mark_retry_failed(:reset_solver_registry, request, backend: CountingSolver)

    assert Registry.circuit_open?(:reset_solver_registry, request, backend: CountingSolver)

    assert :ok = Registry.reset(:reset_solver_registry, request: request)

    refute Registry.circuit_open?(:reset_solver_registry, request, backend: CountingSolver)
  end

  test "replies with a crash error when the solver worker exits abnormally" do
    start_supervised!(
      {Registry,
       name: :crashing_solver_registry, max_concurrency: 1, max_queue: 1, circuit_threshold: 2}
    )

    request =
      Request.new("https://www.example.test/challenge",
        metadata: %{"wireguard_ip_address" => "10.0.0.2"}
      )

    assert {:error, {:solver_crashed, {%RuntimeError{message: "solver crashed"}, _stacktrace}}} =
             Registry.lookup_or_solve(:crashing_solver_registry, request, backend: CrashingSolver)
  end

  test "rejects lookup_or_solve when circuit is open" do
    start_supervised!(
      {Registry,
       name: :circuit_open_registry, max_concurrency: 1, max_queue: 1, circuit_threshold: 2}
    )

    request =
      Request.new("https://www.example.test/challenge",
        metadata: %{"wireguard_ip_address" => "10.0.0.2"}
      )

    Registry.mark_retry_failed(:circuit_open_registry, request, backend: CountingSolver)
    Registry.mark_retry_failed(:circuit_open_registry, request, backend: CountingSolver)

    assert {:error, {:solver_circuit_open, %{open?: true}}} =
             Registry.lookup_or_solve(:circuit_open_registry, request, backend: CountingSolver)
  end

  test "deduplicates concurrent solves for the same host+key" do
    test_pid = self()

    start_supervised!(
      {Registry,
       name: :dedup_solver_registry, max_concurrency: 2, max_queue: 1, circuit_threshold: 2}
    )

    request =
      Request.new("https://dedup.example.test/challenge",
        metadata: %{"wireguard_ip_address" => "10.0.0.2"}
      )

    task_a =
      Task.async(fn ->
        Registry.lookup_or_solve(:dedup_solver_registry, request,
          backend: CountingSolver,
          notify_pid: test_pid,
          solver_delay_ms: 200
        )
      end)

    assert_receive {:solver_called, "https://dedup.example.test/challenge", _}, 1_000

    task_b =
      Task.async(fn ->
        Registry.lookup_or_solve(:dedup_solver_registry, request,
          backend: CountingSolver,
          notify_pid: test_pid
        )
      end)

    result_a = Task.await(task_a, 2_000)
    result_b = Task.await(task_b, 2_000)

    assert {:ok, _} = result_a
    assert result_a == result_b
    refute_receive {:solver_called, "https://dedup.example.test/challenge", _}
  end

  test "mark_retry_succeeded clears failure count" do
    start_supervised!(
      {Registry,
       name: :succeeded_registry, max_concurrency: 1, max_queue: 1, circuit_threshold: 3}
    )

    request =
      Request.new("https://www.example.test/challenge",
        metadata: %{"wireguard_ip_address" => "10.0.0.2"}
      )

    Registry.mark_retry_failed(:succeeded_registry, request, backend: CountingSolver)

    assert :ok =
             Registry.mark_retry_succeeded(:succeeded_registry, request, backend: CountingSolver)

    refute Registry.circuit_open?(:succeeded_registry, request, backend: CountingSolver)
  end

  test "stats returns registry state" do
    start_supervised!(
      {Registry, name: :stats_registry, max_concurrency: 1, max_queue: 1, circuit_threshold: 2}
    )

    stats = Registry.stats(:stats_registry)

    assert stats.active_count == 0
    assert stats.queued_count == 0
    assert stats.inflight_keys == []
    assert stats.circuits == %{}
    assert stats.completed == %{}
  end

  test "circuit auto-expires after open_ms and accepts new solves" do
    start_supervised!(
      {Registry,
       name: :expiry_registry,
       max_concurrency: 1,
       max_queue: 1,
       circuit_threshold: 2,
       circuit_open_ms: 1}
    )

    request =
      Request.new("https://expiry.example.test/challenge",
        metadata: %{"wireguard_ip_address" => "10.0.0.2"}
      )

    Registry.mark_retry_failed(:expiry_registry, request, backend: CountingSolver)
    Registry.mark_retry_failed(:expiry_registry, request, backend: CountingSolver)

    assert Registry.circuit_open?(:expiry_registry, request, backend: CountingSolver)

    Process.sleep(5)

    refute Registry.circuit_open?(:expiry_registry, request, backend: CountingSolver)
  end

  test "solver returning error result is tracked in completed" do
    start_supervised!(
      {Registry,
       name: :error_result_registry, max_concurrency: 1, max_queue: 1, circuit_threshold: 3}
    )

    request =
      Request.new("https://error.example.test/challenge",
        metadata: %{"wireguard_ip_address" => "10.0.0.2"}
      )

    result =
      Registry.lookup_or_solve(:error_result_registry, request,
        backend: CountingSolver,
        solver_result: {:error, :test_failure}
      )

    assert {:error, :test_failure} = result

    stats = Registry.stats(:error_result_registry)
    assert map_size(stats.completed) == 1
    [{_key, entry}] = Map.to_list(stats.completed)
    assert entry.status == {:error, :test_failure}
  end

  test "reset with wireguard_ip_address clears matching circuits" do
    start_supervised!(
      {Registry,
       name: :bucket_reset_registry, max_concurrency: 1, max_queue: 1, circuit_threshold: 2}
    )

    request =
      Request.new("https://bucket.example.test/challenge",
        metadata: %{"wireguard_ip_address" => "10.0.0.2"}
      )

    Registry.mark_retry_failed(:bucket_reset_registry, request, backend: CountingSolver)
    Registry.mark_retry_failed(:bucket_reset_registry, request, backend: CountingSolver)
    assert Registry.circuit_open?(:bucket_reset_registry, request, backend: CountingSolver)

    assert :ok = Registry.reset(:bucket_reset_registry, wireguard_ip_address: "10.0.0.2")

    refute Registry.circuit_open?(:bucket_reset_registry, request, backend: CountingSolver)
  end

  test "ignores unknown task refs in handle_info" do
    start_supervised!(
      {Registry,
       name: :unknown_ref_registry, max_concurrency: 1, max_queue: 1, circuit_threshold: 2}
    )

    pid = GenServer.whereis(:unknown_ref_registry)
    fake_ref = make_ref()
    send(pid, {fake_ref, {:ok, %{}}})
    send(pid, {:DOWN, fake_ref, :process, self(), :normal})

    stats = Registry.stats(:unknown_ref_registry)
    assert stats.active_count == 0
  end

  defp wait_until(fun, attempts \\ 20)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: flunk("condition not met in time")
end
