defmodule Parlora.ContextUpdate do
  @moduledoc "Concise provider context with command and task correlation."
  @type kind :: :quiet | :speakable | :instruction
  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          content: String.t(),
          delegation_id: String.t() | nil,
          provider_generation: non_neg_integer(),
          task_id: String.t() | nil,
          task_revision: pos_integer() | nil
        }
  defstruct [:id, :kind, :content, :delegation_id, :provider_generation, :task_id, :task_revision]
end
