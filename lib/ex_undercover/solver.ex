defmodule ExUndercover.Solver do
  @callback solve(binary(), keyword()) :: {:ok, map()} | {:error, term()}

  @spec solve(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def solve(url, opts \\ []) do
    backend = Keyword.get(opts, :backend, ExUndercover.Solver.Chrome)
    backend.solve(url, opts)
  end
end
