defmodule ExUndercover.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {ExUndercover.ProfileRegistry, []},
      {ExUndercover.CookieJar, []},
      {ExUndercover.Rotator, []},
      {Task.Supervisor, name: ExUndercover.Solver.TaskSupervisor},
      {ExUndercover.Solver.Registry, []}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ExUndercover.Supervisor)
  end
end
