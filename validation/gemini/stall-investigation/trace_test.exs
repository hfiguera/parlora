# Run in the standalone OrderDesk consumer: MIX_ENV=test mix run /absolute/path/trace_test.exs
Code.require_file("trace.exs", __DIR__)
ExUnit.start(autorun: false)

defmodule ParloraGeminiStallTraceTest do
  use ExUnit.Case
  alias Parlora.{BackendResult, Event}

  test "PCM summaries distinguish zero, quiet, and energetic input without retaining samples" do
    assert %{samples: 240, peak: 0, rms: +0.0, above_threshold?: false} =
             ParloraGeminiStallTrace.pcm_summary(:binary.copy(<<0, 0>>, 240))

    assert %{peak: 100, above_threshold?: false} =
             ParloraGeminiStallTrace.pcm_summary(:binary.copy(<<100::little-signed-16>>, 240))

    assert %{samples: 2, peak: 32768, above_threshold?: true} =
             ParloraGeminiStallTrace.pcm_summary(
               <<-32768::little-signed-16, 32767::little-signed-16>>
             )

    assert %{samples: 0, rms: +0.0} = ParloraGeminiStallTrace.pcm_summary(<<>>)
  end

  test "explicit recording is private, bounded, and cannot capture a second connection" do
    dir = Path.join(System.tmp_dir!(), "parlora-pcm-test-#{System.unique_integer([:positive])}")
    path = Path.join(dir, "metadata.jsonl")
    pcm_path = Path.join(dir, "input.pcm")
    {:ok, sink} = ParloraGeminiStallTrace.start(path, record_pcm_once: pcm_path)

    on_exit(fn ->
      if Process.alive?(sink), do: GenServer.stop(sink)
      File.rm_rf!(dir)
    end)

    alias Parlora.Providers.Gemini.Audio
    time = System.monotonic_time()
    pcm = :binary.copy(<<42::little-signed-16>>, 180 * 16_000 + 320)
    send(sink, {:trace_ts, self(), :return_from, {Audio, :input, 2}, {pcm, nil}, time})
    state = :sys.get_state(sink)
    assert state.recording.closed
    assert state.recording.bytes == 180 * 16_000 * 2
    assert File.stat!(pcm_path).size == 180 * 16_000 * 2
    assert Bitwise.band(File.stat!(pcm_path).mode, 0o777) == 0o600
    send(sink, {:trace_ts, self(), :return_from, {Audio, :input, 2}, {<<99, 0>>, nil}, time})
    :sys.get_state(sink)
    assert File.stat!(pcm_path).size == 180 * 16_000 * 2
    refute inspect(state.recording) =~ inspect(binary_part(pcm, 0, 1_000))
    assert File.read!(path) == ""

    assert {:error, _} =
             ParloraGeminiStallTrace.start(Path.join(dir, "second.jsonl"),
               record_pcm_once: pcm_path
             )
  end

  test "explicit recording closes when its first provider exits" do
    dir = Path.join(System.tmp_dir!(), "parlora-pcm-close-#{System.unique_integer([:positive])}")
    pcm_path = Path.join(dir, "input.pcm")

    {:ok, sink} =
      ParloraGeminiStallTrace.start(Path.join(dir, "metadata.jsonl"), record_pcm_once: pcm_path)

    on_exit(fn ->
      if Process.alive?(sink), do: GenServer.stop(sink)
      File.rm_rf!(dir)
    end)

    alias Parlora.Providers.Gemini.Audio
    time = System.monotonic_time()
    send(sink, {:trace_ts, self(), :return_from, {Audio, :input, 2}, {<<42, 0>>, nil}, time})
    send(sink, {:DOWN, make_ref(), :process, self(), :normal})
    send(sink, {:trace_ts, self(), :return_from, {Audio, :input, 2}, {<<43, 0>>, nil}, time})
    assert :sys.get_state(sink).recording.closed
    assert File.read!(pcm_path) == <<42, 0>>
  end

  test "real conversion tracing captures both signal boundaries and persists only aggregates" do
    {sink, path} = tracer()
    parent = self()

    worker =
      spawn(fn ->
        ParloraGeminiStallTrace.event(nil, nil, %{source: :provider, type: :ready}, sink)
        audio = Parlora.Providers.Gemini.Audio.new(%Parlora.AudioFormat{})

        pcm =
          for n <- 0..479, into: <<>>, do: <<round(2000 * :math.sin(n / 10))::little-signed-16>>

        audio =
          Enum.reduce(1..5, audio, fn _, audio ->
            {_pcm, audio} = Parlora.Providers.Gemini.Audio.input(audio, pcm)
            audio
          end)

        Parlora.Providers.Gemini.Audio.close(audio)
        Parlora.Providers.Gemini.Protocol.tool_result("probe-call", %{result: "PRIVATE RESULT"})
        Parlora.Providers.Gemini.Protocol.text("PRIVATE CONTEXT")
        send(parent, {:converted, self()})

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(worker), do: send(worker, :stop) end)
    assert_receive {:converted, ^worker}, 2_000
    ref = :erlang.trace_delivered(worker)
    assert_receive {:trace_delivered, ^worker, ^ref}, 2_000
    state = :sys.get_state(sink)
    assert map_size(state.audio_windows) == 2

    for {_key, window} <- state.audio_windows do
      assert window.frames == 5
      assert window.above_threshold_frames > 0
      assert window.peak > 1000
      assert Enum.all?(Map.values(window), &(is_number(&1) or is_nil(&1)))
    end

    closed = start_supervised!(__MODULE__.ClosedSession)
    send(sink, {:sample, closed})
    assert :sys.get_state(sink).audio_windows == %{}
    rows = File.read!(path) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    signals = Enum.filter(rows, &(&1["kind"] == "input_signal"))
    assert length(signals) == 2
    assert Enum.all?(signals, &(&1["frames"] == 5))
    assert Enum.any?(rows, &(&1["kind"] == "client_content_built"))
    tool = Enum.find(rows, &(&1["kind"] == "tool_response_built"))

    assert [%{"id" => "probe-call", "scheduling" => "WHEN_IDLE", "response_keys" => ["result"]}] =
             tool["responses"]

    refute File.read!(path) =~ "PRIVATE"
    refute File.read!(path) =~ "data"
    send(worker, :stop)
  end

  defmodule ClosedSession do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, nil)
    def init(nil), do: {:ok, nil}

    def handle_call(:status, _from, state),
      do: {:reply, Parlora.Error.tuple(:closed, "Adapter is closed"), state}
  end

  test "a queued sample after disconnect accepts closed and dead session replies" do
    {pid, path} = tracer()
    closed = start_supervised!(__MODULE__.ClosedSession)
    send(pid, {:sample, closed})
    :sys.get_state(pid)
    GenServer.stop(closed)
    send(pid, {:sample, closed})
    :sys.get_state(pid)
    assert Process.alive?(pid)
    assert File.read!(path) == ""
    refute Enum.any?(elem(Process.info(pid, :messages), 1), &match?({:sample, _}, &1))
  end

  defp tracer do
    dir =
      Path.join(System.tmp_dir!(), "parlora-stall-trace-#{System.unique_integer([:positive])}")

    path = Path.join(dir, "metadata.jsonl")
    {:ok, pid} = ParloraGeminiStallTrace.start(path)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(dir)
    end)

    {pid, path}
  end

  test "completed and failed BackendResult structs are safe and their contents are omitted" do
    {pid, path} = tracer()

    for type <- [:request_completed, :request_failed] do
      send(
        pid,
        {:parlora_event,
         %Event{
           type: type,
           source: :backend,
           session_id: "test",
           request_id: "lookup",
           payload: %BackendResult{status: :completed, summary: "PRIVATE RESULT"}
         }}
      )
    end

    :sys.get_state(pid)
    text = File.read!(path)
    assert text =~ "request_completed"
    assert text =~ "request_failed"
    refute text =~ "PRIVATE RESULT"
    assert Process.alive?(pid)
  end

  test "a real Jido lookup completes and delivers context while capture stays alive" do
    {pid, path} = tracer()

    {:ok, session} =
      OrderDesk.start_session(
        {Parlora.Channels.LocalAudio, device: :synthetic},
        {OrderDesk.ScriptedProvider, observer: self(), audio: false},
        context_policy:
          {OrderDesk.AppPolicy, [classify: fn _ -> {:ok, %{intent: "status", order: "124"}} end]}
      )

    on_exit(fn -> if Process.alive?(session), do: Parlora.close(session, :cancel) end)
    assert_receive {:scripted_provider, provider}, 2_000
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}, 2_000
    :sys.get_state(pid)
    OrderDesk.ScriptedProvider.say(provider, "Check order 124")
    OrderDesk.ScriptedProvider.delegate(provider, "lookup")
    assert_receive {:context, update}, 3_000
    assert update.content =~ "Order 124 is out for delivery"
    :sys.get_state(pid)
    assert Process.alive?(pid)
    assert Process.alive?(session)
    assert Enum.any?(Parlora.status(session).jobs, fn {_id, job} -> job.status == :completed end)
    assert File.read!(path) =~ "request_completed"
    refute File.read!(path) =~ "Order 124 is out for delivery"
  end

  test "observer death cannot terminate its server owner" do
    parent = self()

    dir =
      Path.join(
        System.tmp_dir!(),
        "parlora-stall-isolation-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)

    {owner, monitor} =
      spawn_monitor(fn ->
        {:ok, tracer} = ParloraGeminiStallTrace.start(Path.join(dir, "metadata.jsonl"))
        send(parent, {:started, self(), tracer})

        receive do
          :ping -> send(parent, :owner_alive)
        end
      end)

    assert_receive {:started, ^owner, tracer}, 1_000
    trace_monitor = Process.monitor(tracer)
    Process.exit(tracer, :kill)
    assert_receive {:DOWN, ^trace_monitor, :process, ^tracer, :killed}
    assert Process.alive?(owner)
    send(owner, :ping)
    assert_receive :owner_alive
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    :telemetry.detach({ParloraGeminiStallTrace, tracer})
  end

  test "wire summaries and crash status exclude private values" do
    summary =
      ParloraGeminiStallTrace.summarize(%{
        "serverContent" => %{
          "inputTranscription" => %{"text" => "PRIVATE CAPTION", "finished" => true},
          "modelTurn" => %{"parts" => [%{"inlineData" => %{"data" => "PRIVATE AUDIO"}}]}
        },
        "sessionResumptionUpdate" => %{"newHandle" => "PRIVATE HANDLE"},
        "toolCall" => %{
          "functionCalls" => [
            %{
              "id" => "id",
              "name" => "delegate_to_backend",
              "args" => %{"request" => "PRIVATE ARGS"}
            }
          ]
        }
      })

    refute Jason.encode!(summary) =~ "PRIVATE"

    status =
      ParloraGeminiStallTrace.format_status(%{
        state: %{count: 1, bytes: 2, secret: "PRIVATE"},
        message: %{result: "PRIVATE"}
      })

    refute inspect(status) =~ "PRIVATE"
  end
end

result = ExUnit.run()
if result.failures != 0, do: System.halt(1)
