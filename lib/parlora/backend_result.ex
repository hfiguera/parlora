defmodule Parlora.BackendResult do
  @moduledoc "Verified backend outcome; cancellation does not imply reversal of side effects."
  @type status :: :completed | :failed | :cancelled
  @type t :: %__MODULE__{
          request_id: String.t(),
          task_id: String.t(),
          task_revision: pos_integer(),
          provider_generation: non_neg_integer(),
          status: status(),
          facts: map(),
          summary: String.t() | nil,
          error: Parlora.Error.t() | nil,
          metadata: map()
        }
  defstruct [
    :request_id,
    :task_id,
    :task_revision,
    :provider_generation,
    :status,
    :summary,
    :error,
    facts: %{},
    metadata: %{}
  ]
end
