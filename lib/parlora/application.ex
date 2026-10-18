defmodule Parlora.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Parlora.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Parlora.Sessions}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Parlora.Supervisor)
  end
end
