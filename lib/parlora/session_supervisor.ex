defmodule Parlora.SessionSupervisor do
  @moduledoc false
  use Supervisor

  # OTP retains both init arguments and child MFAs in supervisor diagnostics.
  # Keep startup options opaque in both places.
  def start_link(options), do: Supervisor.start_link(__MODULE__, fn -> options end)
  def via(id, role), do: {:via, Registry, {Parlora.Registry, {id, role}}}

  def start_tasks(id) do
    {:ok, tasks} = Task.Supervisor.start_link(name: via(id, :tasks))
    Parlora.ProcessTree.register(tasks, tasks: true)
    {:ok, tasks}
  end

  @impl true
  def init(startup) do
    options = startup.()
    id = Keyword.fetch!(options, :id)

    children = [
      Supervisor.child_spec({Task.Supervisor, name: via(id, :tasks)},
        start: {__MODULE__, :start_tasks, [id]}
      ),
      {DynamicSupervisor, strategy: :one_for_one, name: via(id, :adapters)},
      Supervisor.child_spec({Parlora.Session, options},
        # Keep credentials out of the child MFA shown in supervisor diagnostics.
        start: {Parlora.Adapter, :start_link, [fn -> Parlora.Session.start_link(options) end]},
        modules: [Parlora.Session],
        restart: :temporary,
        significant: true
      )
    ]

    Supervisor.init(children, strategy: :one_for_all, auto_shutdown: :any_significant)
  end
end
