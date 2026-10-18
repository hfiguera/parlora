defmodule Parlora.Channels.Twilio.Socket do
  @moduledoc """
  WebSock transport for an authenticated and authorized Twilio call.

  The host supplies `start_session: fn channel -> ... end`, setting μ-law as
  the session's `audio_format`, and `event_sink: self()`. Supply authorized
  account/call IDs in `channel_options`. Authenticate before upgrading.
  `on_ready` may send a greeting. The host owns admission and call duration.
  Socket closure tears down the session; it does not issue a Twilio hangup API.
  """
  alias Parlora.Channels.MediaStream.Socket

  def upgrade(conn, options),
    do:
      Socket.upgrade(
        conn,
        options,
        Parlora.Channels.Twilio,
        :parlora_twilio
      )
end
