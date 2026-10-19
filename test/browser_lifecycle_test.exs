defmodule Parlora.BrowserLifecycleTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  alias Parlora.{AdapterInit, AudioFormat, Event, Limits}
  alias Parlora.Channels.Browser
  alias Parlora.Native.Opus

  defp init(limits \\ %Limits{}) do
    %AdapterInit{
      session_id: "lifecycle",
      adapter_id: "browser",
      generation: 0,
      audio_format: %AudioFormat{},
      event_sink: self(),
      limits: limits
    }
  end

  test "signaling owner death closes the peer and codec resources" do
    observer = self()

    owner =
      spawn(fn ->
        receive do
          {:parlora_browser, _channel, :attached} = message -> send(observer, message)
        end

        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn -> Process.exit(owner, :kill) end)
    {:ok, channel} = Browser.start_link(init(), signaling: owner)
    Process.unlink(channel)
    # Native and peer initialization complete asynchronously after start_link.
    # Observe attachment within the startup deadline, not the command timeout.
    assert_receive {:parlora_browser, ^channel, :attached}, %Limits{}.startup_timeout_ms
    state = :sys.get_state(channel)
    refs = Enum.map([channel, state.pc], &Process.monitor/1)
    send(owner, :finish)
    for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, _}, 2_000)
    assert {:error, :closed_or_wrong_kind} = Opus.reset(state.media.encoder)
    assert {:error, :closed_or_wrong_kind} = Opus.reset(state.media.decoder)
    assert_receive {:parlora_event, %Event{type: :failed, payload: %{error: %{code: :closed}}}}
  end

  test "negotiation has a finite deadline even without an enclosing session" do
    {:ok, channel} = Browser.start_link(init(%Limits{startup_timeout_ms: 50}), signaling: self())
    ref = Process.monitor(channel)

    assert_receive {:parlora_event, %Event{type: :failed, payload: %{error: %{code: :timeout}}}},
                   2_000

    assert_receive {:DOWN, ^ref, :process, _, :normal}
  end

  test "malformed offer fails without exposing its contents; foreign signaling is rejected" do
    {:ok, channel} = Browser.start_link(init(), signaling: self())
    assert_receive {:parlora_browser, ^channel, :attached}, %Limits{}.startup_timeout_ms

    task =
      Task.async(fn ->
        Browser.signal(channel, %{"type" => "offer", "sdp" => "private input"})
      end)

    assert {:error, _} = Task.await(task)

    assert {:error, _} =
             Browser.signal(channel, %{"type" => "offer", "sdp" => String.duplicate("x", 65_537)})

    assert :ok = Browser.signal(channel, %{"type" => "offer", "sdp" => "private input"})
    assert_receive {:parlora_event, %Event{type: :failed, payload: payload}}
    refute inspect(payload) =~ "private input"
  end

  test "peer failure is observable and closes its channel" do
    {:ok, channel} = Browser.start_link(init(), signaling: self())
    assert_receive {:parlora_browser, ^channel, :attached}, %Limits{}.startup_timeout_ms
    state = :sys.get_state(channel)
    ref = Process.monitor(channel)
    Process.exit(state.pc, :kill)
    assert_receive {:parlora_event, %Event{type: :failed}}
    assert_receive {:DOWN, ^ref, :process, _, :normal}
    assert {:error, :closed_or_wrong_kind} = Opus.reset(state.media.encoder)
  end

  test "relay-only policy is forwarded and invalid policies are rejected" do
    assert {:error, %{code: :invalid_argument}} =
             Browser.start_link(init(), signaling: self(), ice_transport_policy: :invalid)

    {:ok, channel} =
      Browser.start_link(init(),
        signaling: self(),
        ice_transport_policy: :relay
      )

    assert_receive {:parlora_browser, ^channel, :attached}, %Limits{}.startup_timeout_ms
    state = :sys.get_state(channel)
    assert ExWebRTC.PeerConnection.get_configuration(state.pc).ice_transport_policy == :relay
    # Inspect configuration before expiring negotiation; the real deadline is tested above.
    send(channel, :connect_timeout)
    assert_receive {:parlora_event, %Event{type: :failed, payload: %{error: %{code: :timeout}}}}
  end
end
