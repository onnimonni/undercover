defmodule ExUndercover.SolverTest do
  use ExUnit.Case, async: true

  alias ExUndercover.Solver
  alias ExUndercover.TestSupport.TestSolver

  test "delegates to the configured solver backend" do
    assert {:ok, %{browser: :chrome, title: "Solved"}} =
             Solver.solve("https://example.test", backend: TestSolver)
  end
end
