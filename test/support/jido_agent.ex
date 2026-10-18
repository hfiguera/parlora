defmodule Parlora.TestSupport.LookupAction do
  @moduledoc false
  use Jido.Action,
    name: "lookup",
    schema: [
      input: [type: :map, required: true],
      request_id: [type: :string],
      task_id: [type: :string],
      task_revision: [type: :integer]
    ]

  @impl true
  def run(params, _context) do
    if observer = Map.get(params.input, :gate) do
      send(observer, {:lookup_waiting, params.input.order, self()})

      receive do
        :finish -> :ok
      after
        5_000 -> raise "Test lookup was not released"
      end
    else
      Process.sleep(Map.get(params.input, :delay_ms, 20))
    end

    {:ok, %{status: :completed, last_answer: %{order: params.input.order}}}
  end
end

defmodule Parlora.TestSupport.LookupAgent do
  @moduledoc false
  use Jido.Agent,
    name: "lookup_agent",
    schema: [status: [type: :atom, default: :idle], last_answer: [type: :map, default: %{}]],
    signal_routes: [{"parlora.request", Parlora.TestSupport.LookupAction}]
end
