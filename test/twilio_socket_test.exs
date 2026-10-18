defmodule Parlora.TwilioSocketTest do
  use ExUnit.Case, async: true
  alias Parlora.{AudioFormat, AudioFrame, Event}
  alias Parlora.TestSupport.{MemoryAudio, TwilioPeer}

  @account "AC11111111111111111111111111111111"
  @call "CA22222222222222222222222222222222"
  @stream "MZ33333333333333333333333333333333"
  @url "wss://example.com/media"

  defmodule Route do
    @moduledoc false
    alias Parlora.Channels.Twilio.Endpoint
    alias Parlora.TestSupport.{FakeBackend, MemoryProvider, OrderPolicy}

    def init(observer), do: observer

    def call(conn, observer) do
      call_sid =
        if conn.request_path == "/media/second",
          do: "CA44444444444444444444444444444444",
          else: "CA22222222222222222222222222222222"

      Endpoint.upgrade(conn,
        public_url: "wss://example.com" <> conn.request_path,
        auth_token: "test-token",
        authorize: fn _conn ->
          {:ok,
           [
             channel_options: [
               account_sid: "AC11111111111111111111111111111111",
               call_sid: call_sid
             ],
             start_session: fn channel ->
               result =
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

               {:ok, session} = result
               :ok = Parlora.subscribe(session, observer)
               send(observer, {:socket_session, session, self()})
               result
             end,
             on_ready: fn session -> send(observer, {:socket_ready, session}) end
           ]}
        end
      )
    end
  end

  test "signed network socket substitutes for a channel, carries exact bytes, and cleans up on disconnect" do
    listener = start_supervised!({Bandit, plug: {Route, self()}, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    assert {:error, 403} = TwilioPeer.connect(port, "/media", "invalid")
    refute_receive {:socket_session, _session, _socket}, 10
    signature = :crypto.mac(:hmac, :sha, "test-token", @url) |> Base.encode64()
    {:ok, peer} = TwilioPeer.connect(port, "/media", signature)
    on_exit(fn -> TwilioPeer.close(peer) end)
    assert_receive {:socket_session, session, socket}
    assert_receive {:adapter, :provider, provider}
    assert_receive {:adapter, :backend, backend}

    peer = ready_peer(peer, session)
    data = :binary.copy(<<0, 128, 255, 42>>, 20)

    peer =
      TwilioPeer.send_message(peer, %{
        "event" => "media",
        "sequenceNumber" => "2",
        "streamSid" => @stream,
        "media" => %{
          "track" => "inbound",
          "chunk" => "1",
          "timestamp" => "0",
          "payload" => Base.encode64(data)
        }
      })

    frame = AudioFrame.new(data, AudioFormat.pcmu(), "provider", 0)
    :ok = MemoryAudio.audio(provider, frame)
    {[media, mark], peer} = TwilioPeer.receive_messages(peer, 2)
    assert media["event"] == "media"
    assert Base.decode64!(media["media"]["payload"]) == data
    assert [%{data: ^data, duration_us: 10_000}] = MemoryAudio.drain(provider)

    peer =
      TwilioPeer.send_message(peer, %{
        "event" => "mark",
        "sequenceNumber" => "3",
        "streamSid" => @stream,
        "mark" => mark["mark"]
      })

    assert_receive {:parlora_event,
                    %Event{type: :playback_observed, payload: %{stage: :device_reported_playback}}},
                   1_000

    monitors = for pid <- [session, socket, provider, backend], do: {pid, Process.monitor(pid)}
    TwilioPeer.close(peer)
    for {pid, ref} <- monitors, do: assert_receive({:DOWN, ^ref, :process, ^pid, _reason}, 2_000)
  end

  for failure <- [:provider, :malformed_stream] do
    @failure failure
    test "#{failure} failure tears down the socket and every session adapter" do
      listener = start_supervised!({Bandit, plug: {Route, self()}, ip: {127, 0, 0, 1}, port: 0})
      {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
      signature = :crypto.mac(:hmac, :sha, "test-token", @url) |> Base.encode64()
      {:ok, peer} = TwilioPeer.connect(port, "/media", signature)
      on_exit(fn -> TwilioPeer.close(peer) end)
      assert_receive {:socket_session, session, socket}
      assert_receive {:adapter, :provider, provider}
      assert_receive {:adapter, :backend, backend}
      peer = ready_peer(peer, session)
      monitors = for pid <- [session, socket, provider, backend], do: {pid, Process.monitor(pid)}

      case @failure do
        :provider ->
          :ok =
            MemoryAudio.inject(provider, :failed, %{
              error: Parlora.Error.new(:closed, "Simulated provider loss")
            })

        :malformed_stream ->
          TwilioPeer.send_message(peer, %{
            "event" => "media",
            "sequenceNumber" => "2",
            "streamSid" => @stream
          })
      end

      assert :ok = TwilioPeer.finish_server_close(peer)

      for {pid, ref} <- monitors,
          do: assert_receive({:DOWN, ^ref, :process, ^pid, _reason}, 2_000)
    end
  end

  test "two live sockets own independent sessions and survive the other call hanging up" do
    listener = start_supervised!({Bandit, plug: {Route, self()}, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    first = connect_call(port, "/media", @call, @stream)
    second_stream = "MZ55555555555555555555555555555555"

    second =
      connect_call(port, "/media/second", "CA44444444444444444444444444444444", second_stream)

    on_exit(fn ->
      TwilioPeer.close(first.peer)
      TwilioPeer.close(second.peer)
    end)

    refute Parlora.status(first.session).session_id == Parlora.status(second.session).session_id
    refute first.provider == second.provider
    refute first.backend == second.backend

    for {call, value} <- [{first, 1}, {second, 2}] do
      frame = AudioFrame.new(:binary.copy(<<value>>, 160), AudioFormat.pcmu(), "provider", 0)
      assert :ok = MemoryAudio.audio(call.provider, frame)
    end

    {[first_audio, _mark], _first_peer} = TwilioPeer.receive_messages(first.peer, 2)
    {[second_audio, _mark], second_peer} = TwilioPeer.receive_messages(second.peer, 2)
    assert first_audio["streamSid"] == @stream
    assert second_audio["streamSid"] == second_stream
    assert Base.decode64!(first_audio["media"]["payload"]) == :binary.copy(<<1>>, 160)
    assert Base.decode64!(second_audio["media"]["payload"]) == :binary.copy(<<2>>, 160)

    ref = Process.monitor(first.session)
    TwilioPeer.close(first.peer)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 2_000
    assert Parlora.status(second.session).status == :ready
    assert Parlora.status(second.session).jobs == %{}

    assert :ok =
             MemoryAudio.audio(
               second.provider,
               AudioFrame.new(:binary.copy(<<3>>, 160), AudioFormat.pcmu(), "provider", 1)
             )

    {[audio, _mark], _peer} = TwilioPeer.receive_messages(second_peer, 2)
    assert Base.decode64!(audio["media"]["payload"]) == :binary.copy(<<3>>, 160)
  end

  defp connect_call(port, path, call, stream) do
    signature =
      :crypto.mac(:hmac, :sha, "test-token", "wss://example.com" <> path) |> Base.encode64()

    {:ok, peer} = TwilioPeer.connect(port, path, signature)
    assert_receive {:socket_session, session, socket}
    assert_receive {:adapter, :provider, provider}
    assert_receive {:adapter, :backend, backend}

    %{
      peer: ready_peer(peer, session, call, stream),
      session: session,
      socket: socket,
      provider: provider,
      backend: backend
    }
  end

  defp ready_peer(peer, session, call \\ @call, stream \\ @stream) do
    peer =
      TwilioPeer.send_message(peer, %{
        "event" => "connected",
        "protocol" => "Call",
        "version" => "1.0.0"
      })

    peer =
      TwilioPeer.send_message(peer, %{
        "event" => "start",
        "sequenceNumber" => "1",
        "streamSid" => stream,
        "start" => %{
          "accountSid" => @account,
          "callSid" => call,
          "streamSid" => stream,
          "tracks" => ["inbound"],
          "mediaFormat" => %{
            "encoding" => "audio/x-mulaw",
            "sampleRate" => 8_000,
            "channels" => 1
          }
        }
      })

    assert_receive {:socket_ready, ^session}, 2_000
    peer
  end
end
