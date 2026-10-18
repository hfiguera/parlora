defmodule Parlora.Status do
  @moduledoc """
  Public map returned by `Parlora.status/1`; this module defines types only.

  Optional fields are absent until observed, not inferred. Monotonic timestamps
  are signed microseconds on this VM and cannot be compared across VM restarts.
  `:settled` interpretation does not mean jobs finished. A submitted or uncertain
  job may still be running. Delivery acceptance is not playback confirmation.
  A submitted job reserves capacity while its adapter command may still be
  pending. `admission` tracks that callback: pending, dispatched (`:started`), or
  replied (`:settled`). These labels do not establish that backend work started;
  `started_at_us` and `:request_started` report that separate observation.

  Status omits transcript history, full task inputs and backend results. Retained
  clarification data can contain question text and application-defined input.
  Treat it as application data, not automatically safe public telemetry.
  """
  alias Parlora.ContextSnapshot

  @type lifecycle :: :starting | :ready | :closing
  @type interpretation :: :running | :settled | :unresolved
  @type job_state :: :queued | :submitted | :uncertain | Parlora.BackendResult.status()
  @type delivery ::
          :awaiting_interpretation
          | :awaiting_provider
          | :accepted
          | :unconfirmed
          | :rejected
          | :unknown
          | :stale
          | :not_applicable
  @type playback_stage ::
          :queued
          | :handed_off
          | :cleared
          | :estimated_playback
          | :device_reported_playback
          | :unknown
  @type delegation :: %{
          required(:status) => :pending | :claimed | :cancelled,
          required(:received_at_us) => integer(),
          optional(:task_id) => String.t(),
          optional(:task_revision) => pos_integer(),
          optional(:context_wait) => ContextSnapshot.context_wait(),
          optional(:clarification) => ContextSnapshot.policy_clarification()
        }
  @type job :: %{
          required(:status) => job_state(),
          optional(:admission) => :pending | :started | :settled,
          required(:task_id) => String.t(),
          required(:task_revision) => pos_integer(),
          required(:delegation_id) => String.t() | nil,
          required(:deadline_at_us) => integer() | nil,
          required(:current?) => boolean(),
          optional(:started_at_us) => integer(),
          optional(:completed_at_us) => integer(),
          optional(:delivery) => delivery(),
          optional(:result_command_id) => String.t() | nil,
          optional(:delivery_updated_at_us) => integer(),
          optional(:context_wait) => ContextSnapshot.context_wait(),
          optional(:clarification) => ContextSnapshot.clarification()
        }
  @type playback :: %{
          required(:stage) => playback_stage(),
          required(:observed_at_us) => integer(),
          optional(:evidence) => Parlora.Channel.Capabilities.evidence(),
          optional(:stream_id) => String.t(),
          optional(:sequence) => non_neg_integer(),
          optional(:epoch) => non_neg_integer(),
          optional(:first_sample) => non_neg_integer(),
          optional(:end_sample) => non_neg_integer()
        }
  @type t :: %{
          session_id: String.t(),
          status: lifecycle(),
          provider_activity: :unknown | :in_progress | :idle,
          provider_speech: :unknown | :speaking | :idle,
          context_acknowledgment?: boolean(),
          observed_at_us: integer(),
          interpretation: interpretation(),
          delegations: %{optional(String.t()) => delegation()},
          jobs: %{optional(String.t()) => job()},
          health: Parlora.SessionHealth.t(),
          playback: %{optional(playback_stage()) => playback()},
          output_recovery:
            %{
              token: pos_integer(),
              cause: atom(),
              stage: :reconnecting | :awaiting_user,
              started_at_us: integer()
            }
            | nil
        }
end
