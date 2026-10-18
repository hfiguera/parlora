defmodule Parlora.Channels.Telnyx do
  @moduledoc """
  Incoming Telnyx bidirectional Media Streaming with raw mono PCMU at 8 kHz.

  Supply the authenticated socket owner as `:transport`, and the authorized
  `:call_control_id` and `:call_session_id`. Only that process may submit messages
  or pull output. The host owns signed webhook admission and media authentication.

  Local queues default to 200 ms, outstanding playback to 500 ms and mark timeout
  to 2,000 ms (`:max_age_ms`, `:max_inflight_ms`, `:mark_timeout_ms`). Input reorder
  waits at most `:reorder_ms` (40 by default, 1–200 allowed). Gaps are explicit
  discontinuities. RTP timestamps remain vendor metadata, not an assumed ms clock.

  Stale unsent output is discarded with an `:output_stale` discontinuity; it does
  not close the stream. Missing marks still fail at the finite mark timeout.

  Output packets contain at least 20 ms; a short tail is padded with PCMU silence.
  A mark echoed after clear has an unknown played-or-cleared outcome. Closing the
  channel closes its stream, not the phone call; hangup remains application policy.
  """
  use Parlora.AdapterClient
  @behaviour Parlora.Channel
  alias Parlora.Channels.{MediaStream, Telnyx.Protocol}

  @impl true
  def start_link(init, options), do: MediaStream.start_link(init, options, Protocol)
  @doc "Admits a Telnyx wire message from the authenticated transport owner."
  defdelegate receive_message(pid, message), to: MediaStream
  @doc "Pulls a paced batch of output messages for the authenticated transport owner."
  defdelegate pull(pid), to: MediaStream
end
