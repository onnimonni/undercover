defmodule ExUndercover.TestSupport.TestSolver do
  @behaviour ExUndercover.Solver

  @impl true
  def solve(_url, _opts) do
    {:ok,
     %{
       browser: :chrome,
       cookies: [%{name: "solver", value: "ok"}],
       current_url: "http://solver.local/success",
       title: "Solved",
       body_text: "solver ok",
       headless: true
     }}
  end
end
