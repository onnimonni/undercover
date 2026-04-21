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
