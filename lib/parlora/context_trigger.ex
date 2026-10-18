defmodule Parlora.ContextTrigger do
  @moduledoc "The observation that requests context interpretation."
  @type kind ::
          :delegation
          | :delegation_cancelled
          | :transcript_updated
          | :application_context_updated
          | :backend_clarification
          | :context_wait_expired
  @type t :: %__MODULE__{
          kind: kind(),
          delegation_id: String.t() | nil,
          request_id: String.t() | nil,
          task_id: String.t() | nil
        }
  defstruct [:kind, :delegation_id, :request_id, :task_id]
end
