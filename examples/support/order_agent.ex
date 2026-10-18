defmodule Parlora.Examples.Lookup do
  @moduledoc "A read-only demo lookup with an intentional delay to exercise corrections."
  use Jido.Action,
    name: "lookup_order",
    schema: [
      input: [type: :map, required: true],
      request_id: [type: :string],
      task_id: [type: :string],
      task_revision: [type: :integer]
    ]

  @impl true
  def run(params, _context) do
    order = params.input.order
    Process.sleep(if order == "123", do: 12_000, else: 3_000)

    delivery =
      case order do
        "123" -> "Order 123 shipped yesterday and arrives on Friday."
        "124" -> "Order 124 is out for delivery today."
        _unknown -> "Order #{order} was not found in the example catalog. No action was taken."
      end

    {:ok, %{status: :completed, last_answer: %{order: order, summary: delivery}}}
  end
end

defmodule Parlora.Examples.OrderAgent do
  @moduledoc "Jido signal routes and result state owned by the example application."
  use Jido.Agent,
    name: "order_lookup",
    schema: [status: [type: :atom, default: :idle], last_answer: [type: :map, default: %{}]],
    signal_routes: [{"parlora.request", Parlora.Examples.Lookup}]
end
