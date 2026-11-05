defmodule Parlora.ContextUpdate do
  @moduledoc """
  Concise provider context with command and task correlation.

  `:speakable` lets the model use the content in a reply. Optional `:verbatim`
  asks a supporting provider to synthesize application-supplied text directly.
  Check provider capabilities; currently only Grok implements this kind.
  Submit it through `Parlora.append_context/2` to retain generation and task
  revision checks. Admission does not establish playback or caller consent.
  """
  @type kind :: :quiet | :speakable | :instruction | :verbatim
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
