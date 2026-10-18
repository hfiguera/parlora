defmodule Parlora.ContextDecision do
  @moduledoc """
  An application proposal validated against the current context revision.

  `:start_task` uses either a pending `delegation_id`, or `anchor_task_id` with
  `expected_anchor_revision` for an understood follow-up. Leave `task_id` and
  `expected_task_revision` nil: Parlora allocates the new task and request IDs.
  An anchor validates admission; it is not a parent/child relationship, a target
  to modify, or an idempotency key. The policy still deduplicates follow-ups.

  Decisions about existing tasks use `task_id` and `expected_task_revision`.
  A `:supersede_task` may also claim a pending `delegation_id` atomically for
  the replacement revision. Without it, the existing delegation is retained.
  A `:request_clarification` about an existing task may also name a pending
  `delegation_id` to return the question through that provider call. Both
  references are validated; the task retains the clarification for later replies.
  Anchor fields are only valid for `:start_task`. Mixed/legacy start targets are
  rejected; they are not silently reinterpreted.
  """
  @type kind ::
          :start_task
          | :associate_delegation
          | :update_task
          | :supersede_task
          | :wait_for_context
          | :request_clarification
          | :no_action
  @type t :: %__MODULE__{
          kind: kind(),
          delegation_id: String.t() | nil,
          task_id: String.t() | nil,
          expected_task_revision: pos_integer() | nil,
          anchor_task_id: String.t() | nil,
          expected_anchor_revision: pos_integer() | nil,
          input: map(),
          message: String.t() | nil,
          clarification_key: String.t() | nil,
          recheck_after_ms: 1..60_000 | nil,
          recheck_key: String.t() | nil
        }
  defstruct [
    :kind,
    :delegation_id,
    :task_id,
    :expected_task_revision,
    :anchor_task_id,
    :expected_anchor_revision,
    :message,
    :clarification_key,
    :recheck_after_ms,
    :recheck_key,
    input: %{}
  ]
end
