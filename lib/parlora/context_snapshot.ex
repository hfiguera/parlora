defmodule Parlora.ContextSnapshot do
  @moduledoc """
  Immutable context supplied to the application policy, not a persistence format.

  Transcript entries are newest-arrival-first. `arrival_order` is a context
  revision, not a turn identifier; timestamps may overlap. With the default
  rolling retention, entries form a recent suffix, not the entire conversation.
  `transcript_retention` reports retained entries/encoded bytes, cumulative drops,
  and the latest removed arrival revision. Byte counts use `:erlang.external_size/1`
  per enriched entry and are not model tokens or process memory measurements.
  Compaction leaves approximately 25% headroom, preserving at least the newest
  entry when it fits the full byte budget. An entry larger than that budget fails
  admission instead of being cut mid-caption. `:close` retention fails at either
  bound. Session `:transcripts_compacted` events report the same counters.

  Application context and task/delegation identity survive transcript compaction.
  Historical snapshots held by jobs or the application remain immutable and can
  retain older entries. This bound covers the current snapshot, not all references
  to historical snapshots. Provider-managed conversation memory is independent.
  Delegations include
  both pending and claimed entries. Task request IDs are newest-first and include
  older revisions, not just running work. Inspect `Parlora.status/1` for job state.

  Optional map keys are absent until observed. `clarification` is either a policy
  submission attempt or a backend question; it is not proof the caller heard it.
  Policy submissions carry `delivery: :unconfirmed`; their context revision marks
  submission, not speech or playback. Synchronous rejections create no marker.
  `confirmation` is reserved and currently nil; authorize business actions in the
  application. Additional adapter payload keys are not coordinator guarantees.

  `provider_speech` is `:unknown`, `:speaking`, or `:idle`. Changes revise context
  so an in-flight policy judgment cannot apply to an older speech state. This is
  the provider's reported state, not downstream playback or proof of hearing.
  """
  @type speaker :: :user | :assistant
  @type transcript :: %{
          required(:speaker) => speaker(),
          required(:delta) => String.t(),
          required(:start_ms) => number() | nil,
          required(:end_ms) => number() | nil,
          required(:provider_generation) => non_neg_integer(),
          required(:arrival_order) => non_neg_integer(),
          optional(atom()) => term()
        }
  @type context_wait :: %{
          due_at_us: integer(),
          expired?: boolean(),
          recheck_key: String.t() | nil
        }
  @type policy_clarification :: %{
          context_revision: non_neg_integer(),
          command_id: String.t(),
          delivery: :unconfirmed,
          message: String.t(),
          input: map()
        }
  @type backend_clarification :: %{
          required(:task_revision) => pos_integer(),
          optional(:question) => String.t(),
          optional(atom()) => term()
        }
  @type clarification :: policy_clarification() | backend_clarification()
  @type progress :: %{
          required(:task_revision) => pos_integer(),
          optional(:facts) => map(),
          optional(:summary) => String.t(),
          optional(atom()) => term()
        }
  @type delegation :: %{
          required(:id) => String.t(),
          required(:target) => :client,
          required(:offset_ms) => number() | nil,
          required(:provider_generation) => non_neg_integer(),
          required(:status) => :pending | :claimed | :cancelled,
          required(:received_at_us) => integer(),
          optional(:task_id) => String.t(),
          optional(:task_revision) => pos_integer(),
          optional(:context_wait) => context_wait(),
          optional(:clarification) => policy_clarification(),
          optional(atom()) => term()
        }
  @type task_status :: :submitted | :uncertain | Parlora.BackendResult.status()
  @type task :: %{
          required(:id) => String.t(),
          required(:revision) => pos_integer(),
          required(:input) => map(),
          required(:status) => task_status(),
          required(:request_ids) => [String.t()],
          required(:delegation_id) => String.t() | nil,
          required(:confirmation) => nil,
          optional(:context_wait) => context_wait(),
          optional(:clarification) => clarification(),
          optional(:progress) => progress()
        }
  @type transcript_retention :: %{
          mode: :rolling | :close,
          retained: non_neg_integer(),
          retained_bytes: non_neg_integer(),
          dropped: non_neg_integer(),
          dropped_bytes: non_neg_integer(),
          dropped_through_revision: non_neg_integer() | nil
        }
  @type t :: %__MODULE__{
          session_id: String.t(),
          provider_generation: non_neg_integer(),
          revision: non_neg_integer(),
          provider_speech: :unknown | :speaking | :idle,
          transcripts: [transcript()],
          transcript_retention: transcript_retention(),
          application_context: map(),
          pending_delegations: %{optional(String.t()) => delegation()},
          tasks: %{optional(String.t()) => task()}
        }
  defstruct [
    :session_id,
    :provider_generation,
    revision: 0,
    provider_speech: :unknown,
    transcripts: [],
    transcript_retention: %{
      mode: :rolling,
      retained: 0,
      retained_bytes: 0,
      dropped: 0,
      dropped_bytes: 0,
      dropped_through_revision: nil
    },
    application_context: %{},
    pending_delegations: %{},
    tasks: %{}
  ]
end
