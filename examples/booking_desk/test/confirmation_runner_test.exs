defmodule BookingDesk.ConfirmationRunnerTest.Channel do
  use GenServer
  def start_link(owner), do: GenServer.start_link(__MODULE__, %{owner: owner, drained: false})
  def init(s), do: {:ok, s}
  def handle_call(:output_drained, _from, s), do: {:reply, s.drained, s}
  def handle_call({:drained, flag}, _from, s), do: {:reply, :ok, %{s | drained: flag}}

  def handle_call({:play, pcm, label}, _from, s) do
    send(s.owner, {:played, label, pcm})
    {:reply, :ok, s}
  end
end

defmodule BookingDesk.ConfirmationRunnerTest do
  use ExUnit.Case, async: false

  test "exact confirmation spelling supports spoken zero and phonetic examples without accepting a wrong code" do
    alias BookingDesk.Confirmation
    assert Confirmation.complete?("B D dash C E C E D six o eight.", "BD-CECED608")

    assert Confirmation.complete?(
             "B as in boy, D as in dog, six A four one zero E two eight.",
             "BD-6A410E28"
           )

    assert Confirmation.complete?("BD FB sixty-three DE eighty-six.", "BD-FB63DE86")
    refute Confirmation.complete?("B D dash C E C E D six o nine.", "BD-CECED608")
    refute Confirmation.complete?("B as in cat, D as in dog, 6A410E28", "BD-6A410E28")
    refute Confirmation.complete?("Your confirmation number is", "BD-CECED608")
    refute Confirmation.complete?("BD-CECED608", nil)
  end

  test "the real polling transition waits for the full returned code and drained speech before offering reminders" do
    directory =
      Path.join(System.tmp_dir!(), "booking-confirmation-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    pcm = :binary.copy(<<123::signed-little-16>>, 240)
    File.write!(Path.join(directory, "reminder.pcm"), pcm)
    channel = start_supervised!({BookingDesk.ConfirmationRunnerTest.Channel, self()})

    recorder =
      start_supervised!({BookingDesk.Recorder, directory: Path.join(directory, "capture")})

    readback = start_supervised!({BookingDesk.Readback, []})
    db = :sys.get_state(BookingDesk.Store)

    :ok =
      Exqlite.Sqlite3.execute(
        db,
        "INSERT INTO slots VALUES('confirmation-runner-slot','2026-11-05','Dr. Lee'); INSERT INTO appointments VALUES('confirmation-runner-appointment','p_1002','confirmation-runner-slot','booked','BD-CECED608')"
      )

    on_exit(fn ->
      Exqlite.Sqlite3.execute(
        db,
        "DELETE FROM appointments WHERE id='confirmation-runner-appointment'; DELETE FROM slots WHERE id='confirmation-runner-slot'"
      )
    end)

    now = System.monotonic_time(:millisecond)

    s = %{
      mode: :replay,
      stage: :progress,
      stage_at: now - 10000,
      stage_due: 0,
      speech: :idle,
      last_audio_at: now - 2000,
      booking_result_at: now - 3000,
      booking_request: "confirmation-runner-appointment",
      expected_confirmation: "BD-CECED608",
      text: "You're booked for Thursday.",
      channel: channel,
      recorder: recorder,
      readback: readback,
      clips: directory,
      readback_revision: 0,
      confirmation_readback: true,
      greeting_completed: true
    }

    :ok = GenServer.call(channel, {:drained, true})
    assert BookingDesk.Run.advance(s).stage == :progress
    refute_receive {:played, _, _}, 10

    full = %{
      s
      | text:
          "You're booked for Thursday. Your confirmation is B D dash C E C E D six o eight. Would you like a text reminder 24 hours before?"
    }

    :ok = GenServer.call(channel, {:drained, false})
    assert BookingDesk.Run.advance(full).stage == :progress
    refute_receive {:played, _, _}, 10
    :ok = GenServer.call(channel, {:drained, true})
    assert BookingDesk.Run.advance(full).stage == :reminder
    assert_receive {:played, "reminder", ^pcm}
  end

  test "insurance playback waits for the actual record question and drained assistant audio" do
    directory =
      Path.join(System.tmp_dir!(), "booking-insurance-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    pcm = :binary.copy(<<123::signed-little-16>>, 240)
    File.write!(Path.join(directory, "insurance.pcm"), pcm)
    channel = start_supervised!({BookingDesk.ConfirmationRunnerTest.Channel, self()})

    recorder =
      start_supervised!({BookingDesk.Recorder, directory: Path.join(directory, "capture")})

    readback = start_supervised!({BookingDesk.Readback, []})
    now = System.monotonic_time(:millisecond)

    s = %{
      mode: :replay,
      stage: :identity,
      stage_at: now - 10000,
      stage_due: 0,
      speech: :idle,
      last_audio_at: now - 2000,
      text: "Is Cigna still your insurance?",
      insurance: %{carrier: "Aetna", revision: 1},
      identity_request: "lookup",
      channel: channel,
      recorder: recorder,
      readback: readback,
      clips: directory,
      readback_revision: 0,
      confirmation_readback: false,
      greeting_completed: true
    }

    :ok = GenServer.call(channel, {:drained, true})
    assert BookingDesk.Run.advance(s).stage == :identity
    refute_receive {:played, _, _}, 10
    correct = %{s | text: "I have Aetna on file. Is that still your insurance?"}
    :ok = GenServer.call(channel, {:drained, false})
    assert BookingDesk.Run.advance(correct).stage == :identity
    refute_receive {:played, _, _}, 10
    :ok = GenServer.call(channel, {:drained, true})
    assert BookingDesk.Run.advance(correct).stage == :insurance
    assert_receive {:played, "insurance", ^pcm}
    events = :sys.get_state(recorder).events |> Enum.reverse()
    marker = Enum.find(events, &(&1.name == "assistant:insurance_requested"))
    assert marker.data.carrier == "Aetna"
    assert marker.data.lookup_request == "lookup"
  end
end
