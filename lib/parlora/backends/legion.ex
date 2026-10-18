defmodule Parlora.Backends.Legion do
  @moduledoc """
  Optional Legion 0.6.0 execution in isolated Lua agents.

  Supply `:execution`, a request factory returning `%{model: model_spec,
  task: string, operations: %{name => zero_arity_function}, result: mapper}`.
  Tools call only these operations; their native results, not model claims,
  reach the mapper. All supplied operations must succeed before `Tool.complete()`.
  The model spec supports ReqLLM's `{provider, model, options}` form, allowing
  transport options and controlled model fixtures. The host configures ReqLLM's
  provider credentials separately; api_key is not accepted in tuple defaults.

  Persistence, recovery, delegation and conversation sharing are unsupported.
  Cancellation stops local work and leaves external outcomes uncertain.
  """
  @behaviour Parlora.Backend
  alias Parlora.Backends.Bounded
  @impl true
  def start_link(init, options),
    do: Bounded.start_link(init, options, Parlora.Backends.Legion.Job)

  @impl true
  defdelegate capabilities(pid), to: Bounded
  @impl true
  defdelegate submit(pid, request), to: Bounded
  @impl true
  def update(_pid, _id, _request_id, _replacement),
    do: Parlora.Error.tuple(:unsupported, "Supersede work to change a Legion request")

  @impl true
  defdelegate cancel(pid, id, request_id, reason), to: Bounded
  @impl true
  defdelegate close(pid, id, policy), to: Bounded
end
