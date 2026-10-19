defmodule Parlora.Event do
  @moduledoc """
  A live observation, independent of business completion or confirmed playback.

  Match `source` and `type` before reading `payload`. Named payload types describe
  supported common fields; adapter-specific additions are open map entries, not
  universal guarantees. Correlation IDs belong to the envelope and may be nil
  when no command/request can be identified. `observed_at_us` is signed local
  monotonic time. Event IDs do not imply exactly-once delivery or global ordering.

  `t/2` describes a narrowed event, for example
  `t(:request_completed, Parlora.BackendResult.t())`. Runtime messages are trusted
  adapter observations, not a validated serialization format. Events can contain
  transcripts and application data; applications control retention and disclosure.
  """
  alias Parlora.{AdapterInit, ID}

  @type source :: :session | :channel | :provider | :backend
  @type transcript :: %{
          required(:speaker) => Parlora.ContextSnapshot.speaker(),
          required(:delta) => String.t(),
          required(:start_ms) => number() | nil,
          required(:end_ms) => number() | nil,
          optional(:segment_id) => String.t(),
          optional(atom()) => term()
        }
  @type delegation :: %{
          required(:id) => String.t(),
          required(:target) => :client,
          required(:offset_ms) => number() | nil,
          optional(atom()) => term()
        }
  @type task_submission :: %{
          request: Parlora.BackendRequest.t(),
          admission: :ok | {:error, Parlora.Error.t()}
        }
  @type task_identity :: %{task_id: String.t(), task_revision: pos_integer()}
  @type result_delivery :: %{
          required(:stage) => Parlora.Status.delivery(),
          optional(:task_id) => String.t(),
          optional(:task_revision) => pos_integer(),
          optional(:delegation_id) => String.t() | nil
        }
  @type clarification :: %{
          delegation_id: String.t() | nil,
          task_id: String.t() | nil,
          task_revision: pos_integer() | nil
        }
  @type context_wait :: %{
          target: {:delegation, String.t()} | {:task, String.t(), pos_integer()},
          recheck_after_ms: 1..60_000
        }
  @type playback :: %{
          required(:stage) => Parlora.Status.playback_stage(),
          required(:evidence) => Parlora.Channel.Capabilities.evidence(),
          optional(:stream_id) => String.t(),
          optional(:sequence) => non_neg_integer(),
          optional(:epoch) => non_neg_integer(),
          optional(:first_sample) => non_neg_integer(),
          optional(:end_sample) => non_neg_integer(),
          optional(atom()) => term()
        }
  @type discontinuity :: %{
          required(:cause) => atom(),
          optional(:dropped_bytes) => non_neg_integer(),
          optional(:dropped_frames) => non_neg_integer(),
          optional(:dropped_duration_us) => non_neg_integer(),
          optional(atom()) => term()
        }
  @type context_outcome :: %{
          optional(:error) => Parlora.Error.t(),
          optional(:outcome) => :unknown | :unconfirmed,
          optional(:acceptance) => atom(),
          optional(atom()) => term()
        }
  @typedoc "Browser media measurements, not evidence of lost speech or confirmed audibility."
  @type audio_observation ::
          %{
            cause: :startup_capture_discard,
            boundary: :browser_rtp,
            packets: non_neg_integer(),
            duration_us: non_neg_integer()
          }
          | %{
              cause: :source_queue_empty | :source_resumed | :cleared | :closed,
              boundary: :browser_pcm,
              gap_id: pos_integer(),
              epoch: non_neg_integer(),
              started_at_us: integer(),
              duration_us: non_neg_integer(),
              silence_bytes: non_neg_integer(),
              inserted_silence_us: non_neg_integer(),
              peak_before: non_neg_integer(),
              peak_after: non_neg_integer() | nil,
              source_returned_at_us: integer() | nil,
              source_return_queue_bytes: non_neg_integer() | nil,
              resume_queue_bytes: non_neg_integer() | nil,
              source_unavailable_us: non_neg_integer(),
              recovery_wait_us: non_neg_integer(),
              recovery_target_us: non_neg_integer() | nil,
              recovery_release_reason:
                :deadline
                | :pressure
                | :buffering_disabled
                | :queue_ready
                | :cleared
                | :closed
                | nil
            }
  @type session_closed :: %{
          health: Parlora.SessionHealth.t(),
          finalized?: boolean(),
          usage: map() | nil,
          jobs: %{optional(String.t()) => Parlora.Status.job_state()}
        }
  @type error_payload :: %{required(:error) => Parlora.Error.t(), optional(atom()) => term()}
  @type request_started :: %{
          required(:task_revision) => pos_integer(),
          optional(atom()) => term()
        }
  @type delegation_associated :: %{
          id: String.t(),
          task_id: String.t(),
          task_revision: pos_integer()
        }
  @type session_ready :: %{
          capabilities: %{
            channel: Parlora.Channel.Capabilities.t(),
            provider: Parlora.Provider.Capabilities.t(),
            backend: Parlora.Backend.Capabilities.t()
          }
        }
  @type adapter_ready :: %{
          required(:capabilities) =>
            Parlora.Channel.Capabilities.t()
            | Parlora.Provider.Capabilities.t()
            | Parlora.Backend.Capabilities.t(),
          optional(:format) => Parlora.AudioFormat.t(),
          optional(atom()) => term()
        }
  @type adapter_closed :: %{
          optional(:finalized?) => boolean(),
          optional(:usage) => map() | nil,
          optional(:uncertain_requests) => [String.t()],
          optional(:scope) => atom(),
          optional(:call_ended?) => boolean() | :unknown,
          optional(atom()) => term()
        }
  @type t(event_type, event_payload) :: t(source(), event_type, event_payload)
  @type t(event_source, event_type, event_payload) :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          source: event_source,
          adapter_id: String.t(),
          generation: non_neg_integer(),
          type: event_type,
          observed_at_us: integer(),
          command_id: String.t() | nil,
          request_id: String.t() | nil,
          payload: event_payload,
          metadata: map()
        }
  @type t ::
          t(:transcript_delta, transcript())
          | t(:delegation_requested, delegation())
          | t(:delegation_pending, %{delegation_id: String.t()})
          | t(:delegation_associated, delegation_associated())
          | t(:task_submitted, task_submission())
          | t(:task_queued, task_identity())
          | t(:request_started, request_started())
          | t(:request_progress, Parlora.ContextSnapshot.progress())
          | t(:request_clarification, Parlora.ContextSnapshot.backend_clarification())
          | t(
              :request_completed | :request_failed | :request_cancelled,
              Parlora.BackendResult.t()
            )
          | t(:stale_result, %{result: Parlora.BackendResult.t()})
          | t(:result_delivery, result_delivery())
          | t(:clarification_requested, clarification())
          | t(:context_wait_started, context_wait())
          | t(:context_acknowledged | :context_rejected | :context_submitted, context_outcome())
          | t(:delegation_cancelled, %{id: String.t(), reason: atom()})
          | t(:output_recovery_requested, %{
              token: pos_integer(),
              cause: :output_overflow | :output_stale
            })
          | t(:output_recovered, %{required(:token) => pos_integer(), optional(atom()) => term()})
          | t(:output_interrupted, %{token: non_neg_integer()})
          | t(:provider_activity, %{state: :in_progress | :idle})
          | t(:provider_speech, %{state: :speaking | :idle})
          | t(:response_status, %{
              status: atom(),
              cause: atom(),
              elapsed_ms: non_neg_integer(),
              evidence: :local_observation
            })
          | t(:provider_connection, map())
          | t(:progress_changed, Parlora.SessionHealth.expectation())
          | t(:playback_observed, playback())
          | t(:audio_discontinuity, discontinuity())
          | t(:channel, :audio_observed, audio_observation())
          | t(:failed | :policy_failed | :policy_rejected | :admission_rejected, error_payload())
          | t(:session, :ready, session_ready())
          | t(:channel | :provider | :backend, :ready, adapter_ready())
          | t(:session, :closed, session_closed())
          | t(:channel | :provider | :backend, :closed, adapter_closed())
          | t(:adapter_down, %{
              role: :channel | :provider | :backend | :input_pipeline | :output_pipeline
            })
          | t(
              :disconnected
              | :request_uncertain
              | :update_applied
              | :update_rejected
              | :update_uncertain
              | :cancellation_requested
              | :cancellation_rejected
              | :cancellation_unconfirmed
              | :control_completed
              | :control_failed
              | :usage_updated
              | :usage_final
              | :extension,
              map()
            )

  defstruct [
    :id,
    :session_id,
    :source,
    :adapter_id,
    :generation,
    :type,
    :observed_at_us,
    :command_id,
    :request_id,
    payload: %{},
    metadata: %{}
  ]

  @spec emit(AdapterInit.t(), atom(), atom(), term(), keyword()) :: t()
  def emit(init, source, type, payload \\ %{}, fields \\ []) do
    event =
      struct!(
        __MODULE__,
        Keyword.merge(
          [
            id: ID.new(),
            session_id: init.session_id,
            source: source,
            adapter_id: init.adapter_id,
            generation: init.generation,
            type: type,
            observed_at_us: System.monotonic_time(:microsecond),
            payload: payload
          ],
          fields
        )
      )

    Parlora.Telemetry.event(event)
    send(init.event_sink, {:parlora_event, event})
    :telemetry.execute([:parlora, :event], %{count: 1}, %{source: source, type: type})
    event
  end
end
