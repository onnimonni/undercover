defmodule ExUndercover.TestSupport.CountingSolver do
  @behaviour ExUndercover.Solver

  @default_result %{
    browser: :chrome,
    cookies: [%{name: "solver", value: "ok"}],
    current_url: "http://solver.local/success",
    title: "Solved",
    body_text: "solver ok",
    headless: true
  }

  @impl true
  def solve(url, opts) do
    if pid = Keyword.get(opts, :notify_pid) do
      send(pid, {:solver_called, url, self()})
    end

    Process.sleep(Keyword.get(opts, :solver_delay_ms, 0))

    case Keyword.get(opts, :solver_result, {:ok, @default_result}) do
      fun when is_function(fun, 0) -> fun.()
      other -> other
    end
  end
end
