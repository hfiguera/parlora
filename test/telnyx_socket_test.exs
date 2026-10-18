defmodule Parlora.TelnyxSocketTest do
  use ExUnit.Case, async: true
  alias Parlora.{AudioFormat, AudioFrame, Event}
  alias Parlora.TestSupport.{MemoryAudio, TelnyxPeer, TwilioPeer}

  defmodule Route do
    alias Parlora.Channels.Telnyx.Endpoint
    alias Parlora.TestSupport.{FakeBackend, MemoryProvider, OrderPolicy}
    def init(options), do: options

    def call(conn, {observer, owner}) do
      Endpoint.upgrade(conn,
        authorize: fn _conn, token ->
          if Plug.Crypto.secure_compare(token, String.duplicate("t", 43)) do
            {:ok,
             [
               channel_options: [call_control_id: "call", call_session_id: "session"],
               lifecycle_owner: owner,
               start_session: fn channel ->
                 {:ok, session} =
                   Parlora.start_session(
                     channel: channel,
                     audio_format: AudioFormat.pcmu(),
                     provider:
                       {MemoryProvider,
                        observer: observer,
                        capabilities: Parlora.Providers.OpenAI.Protocol.capabilities()},
                     backend: {FakeBackend, observer: observer},
                     context_policy: {OrderPolicy, []},
                     event_sink: self()
                   )

                 :ok = Parlora.subscribe(session, observer)
                 send(observer, {:socket_session, session, self()})
                 {:ok, session}
               end
             ]}
          else
            {:error, :invalid_token}
          end
        end
      )
    end
  end

  test "authenticated real socket exchanges bytes and process ownership cleans the entire session" do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    listener =
      start_supervised!({Bandit, plug: {Route, {self(), owner}}, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    assert {:error, 403} = TwilioPeer.connect_headers(port, "/media", [])

    assert {:error, 403} =
             TwilioPeer.connect_headers(port, "/media", [
               {"x-telnyx-streaming-auth-token", String.duplicate("x", 43)}
             ])

    refute_receive {:socket_session, _pid, _socket}, 10

    {:ok, peer} =
      TwilioPeer.connect_headers(port, "/media", [
        {"x-telnyx-streaming-auth-token", String.duplicate("t", 43)}
      ])

    on_exit(fn ->
      TwilioPeer.close(peer)
      Process.exit(owner, :kill)
    end)

    assert_receive {:socket_session, session, socket}
    assert_receive {:adapter, :provider, provider}
    assert_receive {:adapter, :backend, backend}
    peer = Enum.reduce(TelnyxPeer.handshake(), peer, &TwilioPeer.send_message(&2, &1))
    assert_receive {:parlora_event, %Event{type: :ready, source: :session}}
    bytes = :binary.copy(<<1, 127, 255, 0>>, 40)
    peer = TwilioPeer.send_message(peer, TelnyxPeer.media(bytes))
    :ok = MemoryAudio.audio(provider, AudioFrame.new(bytes, AudioFormat.pcmu(), "provider", 0))
    {[packet, mark], peer} = TwilioPeer.receive_messages(peer, 2)
    assert Base.decode64!(packet["media"]["payload"]) == bytes

    peer =
      TwilioPeer.send_message(peer, %{
        "event" => "mark",
        "sequence_number" => "3",
        "stream_id" => "stream",
        "mark" => mark["mark"]
      })

    assert_receive {:parlora_event,
                    %Event{type: :playback_observed, payload: %{boundary: :telnyx_mark}}}

    Process.sleep(60)
    assert [%{data: ^bytes}] = MemoryAudio.drain(provider)
    monitors = for pid <- [session, socket, provider, backend], do: {pid, Process.monitor(pid)}
    send(owner, :stop)
    assert :ok = TwilioPeer.finish_server_close(peer)
    for {pid, ref} <- monitors, do: assert_receive({:DOWN, ^ref, :process, ^pid, _reason}, 2_000)
  end
end
