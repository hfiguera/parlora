defmodule Parlora.TestSupport.BrowserPeer do
  @moduledoc false
  alias ExWebRTC.{ICECandidate, MediaStreamTrack, PeerConnection, SessionDescription}
  alias Parlora.Channels.Browser

  def connect(channel) do
    {:ok, pc} = PeerConnection.start_link(audio_codecs: [:opus], video_codecs: [])
    track = MediaStreamTrack.new(:audio)
    {:ok, _sender} = PeerConnection.add_track(pc, track)
    {:ok, offer} = PeerConnection.create_offer(pc)
    :ok = PeerConnection.set_local_description(pc, offer)
    :ok = Browser.signal(channel, SessionDescription.to_json(offer))
    negotiate(channel, pc, System.monotonic_time(:millisecond) + 10_000)
    {pc, track}
  end

  defp negotiate(channel, pc, deadline) do
    receive do
      {:parlora_browser, ^channel, {:signal, %{"type" => "answer"} = answer}} ->
        :ok = PeerConnection.set_remote_description(pc, SessionDescription.from_json(answer))
        negotiate(channel, pc, deadline)

      {:parlora_browser, ^channel, {:signal, %{"candidate" => candidate}}} ->
        :ok = PeerConnection.add_ice_candidate(pc, ICECandidate.from_json(candidate))
        negotiate(channel, pc, deadline)

      {:ex_webrtc, ^pc, {:ice_candidate, candidate}} ->
        :ok =
          Browser.signal(channel, %{
            "type" => "candidate",
            "candidate" => ICECandidate.to_json(candidate)
          })

        negotiate(channel, pc, deadline)

      {:ex_webrtc, ^pc, {:connection_state_change, :connected}} ->
        :ok

      {:ex_webrtc, ^pc, {:connection_state_change, :failed}} ->
        raise "Test peer failed"

      {:ex_webrtc, ^pc, _event} ->
        negotiate(channel, pc, deadline)
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        raise "Test peer connection timed out"
    end
  end
end
