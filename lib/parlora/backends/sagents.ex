defmodule Parlora.Backends.Sagents do
  @moduledoc """
  Runs one isolated, bounded Sagents execution per admitted request.

  Install optional `sagents == 0.17.1`. Configure `:agent` as a function receiving
  a BackendRequest and returning `{:ok, agent, state}`, `:result` as a function
  mapping a successful terminal tool result to `%{status: ..., facts: ..., summary: ...}`,
  and `:completion_tool` as its name. `:max_runs` defaults to 8 (maximum 100).

  The application constructs the model, credentials and synchronous tools. Build
  the agent with `replace_default_middleware: true` and empty middleware; default
  filesystem/subagent tools, custom modes, fallbacks and asynchronous tools are
  deliberately unsupported. This makes execution ownership and authority explicit.

  Cancellation is advisory: it stops local execution and reports an uncertain
  external outcome. It never confirms reversal of an already executed tool.
  Updates, model token streams, progress and clarification are not advertised.
  """
  @behaviour Parlora.Backend
  alias Parlora.Backends.Bounded
  @impl true
  def start_link(init, options),
    do: Bounded.start_link(init, options, Parlora.Backends.Sagents.Job)

  @impl true
  defdelegate capabilities(pid), to: Bounded
  @impl true
  defdelegate submit(pid, request), to: Bounded
  @impl true
  def update(_pid, _id, _request_id, _replacement),
    do: Parlora.Error.tuple(:unsupported, "Supersede work to change a Sagents request")

  @impl true
  defdelegate cancel(pid, id, request_id, reason), to: Bounded
  @impl true
  defdelegate close(pid, id, policy), to: Bounded
end
