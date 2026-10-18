defmodule Parlora.SessionHealth do
  @moduledoc """
  Content-free observations in `Parlora.status/1` under `:health`.

  Input/output counters count successful pipeline writes to the provider/channel
  adapter, including silence. They do not prove network receipt, speech, audibility,
  or an answer. Counters are approximate concurrent samples, not atomic bundles.
  Event counts cover observations delivered to the coordinator, not all wire events.
  Timestamps are signed VM-local monotonic microseconds; absent activity has nil time.

  `Parlora.expect_progress/4` arms a single deadline (1–300,000 milliseconds).
  `until:` selects `:assistant_caption` (default), `:user_caption`, `:delegation`,
  `:conversation` (any of these three), or `:explicit`. Automatic resolution requires a new, nonblank matching caption
  or a delegation observed after arming and processed before the deadline. It
  establishes activity only, not correctness or correlation with a particular turn.
  Use `:explicit` and `Parlora.resolve_progress/3` when the host needs semantic or
  request-specific completion. Acknowledgments and audio alone never satisfy it.

  `on_timeout: :notify` (default) emits a session `:progress_changed` event with
  `status: :timed_out` and leaves the session ready. `:close` also emits `:failed`
  with `cause: :progress_timeout` and starts bounded cancellation/cleanup. External
  work can remain uncertain. No reconnect or work replay occurs automatically.

  No deadline runs by default. The host arms it before the operation it expects,
  cancels it on interruption or a changed expectation, and chooses a suitable budget.
  Silence, muted input and long backend work are not independently classified as faults.
  Closing cancels a pending expectation. Ordinary activity never extends its deadline.

  One current/latest expectation is retained. Repeated IDs with identical settings
  are idempotent, including after resolution; conflicting reuse is rejected. Records
  are bounded by `max_records`; exhaustion rejects further expectations. IDs appear
  in status/events, so use opaque IDs rather than user content.
  """

  @type activity :: %{count: non_neg_integer(), last_at_us: integer()}
  @type audio :: %{
          frames: non_neg_integer(),
          bytes: non_neg_integer(),
          last_at_us: integer() | nil
        }
  @type expectation :: %{
          required(:id) => String.t(),
          required(:status) => :pending | :observed | :completed | :cancelled | :timed_out,
          required(:until) =>
            :assistant_caption | :user_caption | :delegation | :conversation | :explicit,
          required(:on_timeout) => :notify | :close,
          required(:timeout_ms) => pos_integer(),
          required(:started_at_us) => integer(),
          required(:deadline_at_us) => integer(),
          optional(:resolved_at_us) => integer()
        }
  @type t :: %{
          input_forwarded: audio(),
          output_forwarded: audio(),
          observations: %{
            optional(
              :provider_event
              | :user_caption
              | :assistant_caption
              | :delegation
              | :playback_event
            ) => activity()
          },
          expectation: expectation() | nil
        }
end
