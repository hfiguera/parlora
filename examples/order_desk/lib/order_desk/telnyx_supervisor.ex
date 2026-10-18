defmodule OrderDesk.TelnyxSupervisor do
  @moduledoc "Keeps the call manager and its command workers in one failure domain."
  use Supervisor

  def start_link(config), do: Supervisor.start_link(__MODULE__, config, name: __MODULE__)

  @impl true
  def init(config) do
    Supervisor.init(
      [
        {Task.Supervisor, name: OrderDesk.TelnyxCommands},
        {OrderDesk.TelnyxGate, config: config, task_supervisor: OrderDesk.TelnyxCommands}
      ],
      strategy: :one_for_all
    )
  end
end
