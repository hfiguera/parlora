defmodule OrderDesk.Lookup do
  @moduledoc "Jido database queries and delivery drafts; voice cannot commit a change."
  use Jido.Action,
    name: "lookup_order",
    schema: [
      input: [type: :map, required: true],
      request_id: [type: :string],
      task_id: [type: :string],
      task_revision: [type: :integer]
    ]

  @impl true
  def run(params, _context), do: OrderDesk.Operations.execute(params)
end

defmodule OrderDesk.ConfirmDelivery do
  @moduledoc "Jido wrapper for the application's browser-only confirmation operation."
  use Jido.Action,
    name: "confirm_delivery",
    schema: [actor: [type: :string, required: true], proposal: [type: :string, required: true]]

  @impl true
  def run(params, _context), do: OrderDesk.Operations.confirm(params)
end

defmodule OrderDesk.OrderAgent do
  @moduledoc "Jido signal routes and result state owned by the example application."
  use Jido.Agent,
    name: "order_lookup",
    schema: [status: [type: :atom, default: :idle], last_answer: [type: :map, default: %{}]],
    signal_routes: [{"parlora.request", OrderDesk.Lookup}]
end
