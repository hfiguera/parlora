defmodule Parlora.ContextPolicy do
  @moduledoc """
  Interprets conversation and application state into backend task decisions.

  Configure a session with `context_policy: {MyApp.Policy, options}`. Parlora calls
  `c:interpret/3` outside the coordinator and audio processes with an immutable
  `Parlora.ContextSnapshot`, a `Parlora.ContextTrigger`, and your options.

  Return `{:ok, decisions}` using `Parlora.ContextDecision`, or `{:ok, []}` when
  no action is needed. Start tasks from a pending delegation, associate a later
  delegation with existing work, ask for clarification, or supersede a task when
  the caller corrects it. Decisions are checked against current context and task
  revisions before admission.

  Transcripts may be a retained recent suffix. Inspect
  `snapshot.transcript_retention` before relying on absent conversational details;
  preserve important facts in application context or your own storage. Compaction
  revises context, so decisions from older snapshots are checked again against
  current context before effects are admitted. Task and command records are not
  evicted to make room for transcripts.

  The policy is application code; it may use deterministic rules or an
  interpretation service. Its decisions do not authorize business side effects.
  Validate permissions and confirmations in application operations too. See
  `Parlora.ContextDecision` for decision shapes and revision requirements.
  """
  @callback interpret(Parlora.ContextSnapshot.t(), Parlora.ContextTrigger.t(), keyword()) ::
              {:ok, [Parlora.ContextDecision.t()]} | {:error, Parlora.Error.t()}
end
