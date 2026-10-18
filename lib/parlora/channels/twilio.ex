defmodule Parlora.Channels.Twilio do
  @moduledoc """
  Bidirectional Twilio Media Streams with raw mono μ-law at 8 kHz.

  Supply the authenticated socket owner as `:transport`, and the authorized
  `:account_sid` and `:call_sid`. Only that owner may submit Twilio messages or
  pull outbound packets. The host owns authentication and call authorization.
  Closing this adapter closes its stream; it does not assert that the call ended.

  `:max_age_ms` defaults to 200 for local channel queues; `:mark_timeout_ms`
  defaults to 2,000; `:max_inflight_ms` defaults to 500. Unacknowledged audio
  is bounded independently of the local queue. A mark after a clear has an
  unknown played-or-cleared outcome, never successful playback evidence.

  Stale unsent output is discarded with an `:output_stale` discontinuity; it does
  not close the stream. Missing marks still fail at the finite mark timeout.
  """
  use Parlora.AdapterClient
  @behaviour Parlora.Channel
  alias Parlora.Channels.{MediaStream, Twilio.Protocol}

  @impl true
  def start_link(init, options), do: MediaStream.start_link(init, options, Protocol)
  @doc "Admits a Twilio wire message from the authenticated transport owner."
  defdelegate receive_message(pid, message), to: MediaStream
  @doc "Pulls a paced batch of output messages for the authenticated transport owner."
  defdelegate pull(pid), to: MediaStream
end
