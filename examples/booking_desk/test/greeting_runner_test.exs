defmodule BookingDesk.GreetingRunnerTest.Channel do
  use GenServer
  def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
  def init(owner), do: {:ok, owner}
  def handle_call(:output_drained, _from, owner), do: {:reply, true, owner}

  def handle_call({:play, pcm, label}, _from, owner) do
    send(owner, {:caller_played, label, pcm})
    {:reply, :ok, owner}
  end
end

defmodule BookingDesk.GreetingRunnerTest do
  use ExUnit.Case, async: true

  test "the real polling transition waits for the greeting and records it before caller playback" do
    directory =
      Path.join(System.tmp_dir!(), "booking-greeting-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    pcm = :binary.copy(<<123::signed-little-16>>, 240)
    File.write!(Path.join(directory, "search.pcm"), pcm)
    channel = start_supervised!({BookingDesk.GreetingRunnerTest.Channel, self()})

    recorder =
      start_supervised!({BookingDesk.Recorder, directory: Path.join(directory, "capture")})

    readback = start_supervised!({BookingDesk.Readback, []})
    now = System.monotonic_time(:millisecond)

    state = %{
      mode: :replay,
      stage: :greeting,
      stage_at: now - 5000,
      stage_due: 0,
      speech: :idle,
      last_audio_at: now - 1500,
      text: "Cedarwood Family Clinic. How can I help?",
      greeting_audio: false,
      greeting_completed: false,
      confirmation_readback: false,
      readback_revision: 0,
      channel: channel,
      recorder: recorder,
      readback: readback,
      clips: directory
    }

    assert BookingDesk.Run.advance(state).stage == :greeting
    refute_receive {:caller_played, _, _}, 10
    next = BookingDesk.Run.advance(%{state | greeting_audio: true})
    assert next.stage == :search
    assert next.greeting_completed
    assert_receive {:caller_played, "search", ^pcm}
    events = :sys.get_state(recorder).events |> Enum.reverse()
    markers = Enum.filter(events, &(&1.kind == "marker"))
    assert Enum.map(markers, & &1.name) == ["assistant:greeting_completed", "caller:search"]
  end
end
