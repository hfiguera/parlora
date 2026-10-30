# Jido backend

`Parlora.Backends.Jido` runs a Jido agent defined by your application for each admitted
request. For a complete application with a context policy and event receiver,
start with [Your first working session](first-session.md). The order example below
shows how to adapt the integration to an existing application. Jido is optional. Add `{:jido, "~> 2.4.0"}` to your application's
dependencies and supervise an instance:

```elixir
children = [{Jido, name: MyApp.Jido}]
```

A deterministic Jido action can call your database or service directly. A separate
text model is not required. Voice still comes from the session's provider.

## Define an action and agent

The default signal is `parlora.request`. Its data contains `input`, `request_id`,
`task_id`, and `task_revision`. For example:

```elixir
defmodule MyApp.LookupOrder do
  use Jido.Action,
    name: "lookup_order",
    schema: [
      input: [type: :map, required: true],
      request_id: [type: :string],
      task_id: [type: :string],
      task_revision: [type: :integer]
    ]

  def run(%{input: %{order: order, customer_id: customer_id}}, _context) do
    # This application function authorizes the customer and reads the order.
    case MyApp.Orders.fetch_for_customer(customer_id, order) do
      {:ok, facts} -> {:ok, %{status: :completed, last_answer: facts}}
      {:error, _reason} -> {:ok, %{status: :failed, error: %{reason: "Order unavailable"}}}
    end
  end
end

defmodule MyApp.OrderAgent do
  use Jido.Agent,
    name: "order_agent",
    schema: [
      status: [type: :atom, default: :idle],
      last_answer: [type: :map, default: %{}],
      error: [type: :map, default: %{}]
    ],
    signal_routes: [{"parlora.request", MyApp.LookupOrder}]
end
```

`MyApp.Orders.fetch_for_customer/2` is application code. Include its own service
and database timeouts. The [OrderDesk example](../examples/order_desk/README.md)
provides a complete application with real actions, policies, and storage.

## Configure the session backend

```elixir
backend: {Parlora.Backends.Jido,
  agent: MyApp.OrderAgent,
  agent_options: [jido: MyApp.Jido],
  result: fn terminal ->
    %{status: terminal.status, facts: terminal.result}
  end}
```

The result mapper receives Jido completion data (`terminal.result` holds the
agent's `last_answer` on success or `error` on failure) and returns a map with `:status`
and `:facts`, plus optional `:summary`. Status is `:completed`, `:failed`, or an
explicitly verified `:cancelled`. Parlora attaches request, task, revision, and
provider identities. A submitted signal is separate from completed execution.

The context policy supplies the action input. Implement
`c:Parlora.ContextPolicy.interpret/3` to inspect caller transcripts, application
context, and current tasks, then return `Parlora.ContextDecision` values. A new
`:start_task` claims a pending delegation; a correction uses `:supersede_task`
with the current task revision. `Parlora.ContextDecision` documents decision shapes
and revision requirements. Authorize the resulting operation in your application
even when model text suggests it.

## Lifecycle and cancellation

Each request gets a fresh agent and an independent completion observer. Optional
`:signal` customizes how requests map to signals. Optional `:cancel_signal` maps a
request and reason to an advisory cancellation signal. Without that mapping,
cancellation is unsupported.

Cancellation mapping is bounded and does not confirm that work stopped. Only an
explicit terminal `status: :cancelled` confirms cancellation. Neither cancellation
nor a corrected task reverses already performed external effects. Keep writes
idempotent and require confirmation controlled by your application where appropriate.
