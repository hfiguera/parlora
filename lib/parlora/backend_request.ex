defmodule Parlora.BackendRequest do
  @moduledoc "A uniquely identified revision of application-owned work."
  @type t :: %__MODULE__{
          id: String.t(),
          task_id: String.t(),
          task_revision: pos_integer(),
          provider_generation: non_neg_integer(),
          delegation_id: String.t() | nil,
          input: map(),
          context: Parlora.ContextSnapshot.t(),
          deadline_at_us: integer() | nil,
          metadata: map()
        }
  defstruct [
    :id,
    :task_id,
    :task_revision,
    :provider_generation,
    :delegation_id,
    :context,
    :deadline_at_us,
    input: %{},
    metadata: %{}
  ]
end
