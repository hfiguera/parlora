defmodule BookingDesk.ReplayChannel do
  alias Parlora.Channel.Capabilities
  @moduledoc "Paced caller PCM and software playout; no microphone or physical device is implied."
  use GenServer
  use Parlora.AdapterClient
  @behaviour Parlora.Channel
  alias Parlora.{AudioFrame, AudioQueue, Error, Event, Playout}
  @impl true
  def start_link(init, opts), do: GenServer.start_link(__MODULE__, {init, opts})
  def ambience_info(pid), do: GenServer.call(pid, :ambience_info)
  def play(pid, pcm, label), do: GenServer.call(pid, {:play, pcm, label})
  # Full-duplex providers may stream silent PCM continuously. Only queued
  # nonquiet samples can still be part of the greeting the caller must hear.
  def output_drained?(%AudioQueue{} = queue),
    do: Enum.all?(:queue.to_list(queue.items), fn frame -> not audible?(frame.data) end)

  def output_drained?(pid), do: GenServer.call(pid, :output_drained)

  @impl true
  def init({init, opts}) do
    send(Keyword.fetch!(opts, :owner), {:channel, self()})
    send(self(), :ready)

    {:ok,
     %{
       init: init,
       observer: opts[:audio_observer] || opts[:observer],
       recorder: opts[:recorder],
       owner: Keyword.fetch!(opts, :owner),
       input: %AudioQueue{capacity: init.limits.audio_queue_bytes},
       output: %AudioQueue{capacity: init.limits.audio_queue_bytes},
       output_pcm: <<>>,
       pending: <<>>,
       pending_label: nil,
       pending_bytes: 0,
       ambience: opts[:ambience],
       sequence: 0,
       epoch: 0,
       suppressed: false,
       closed: false,
       playout: Playout.new(120, init.limits.audio_queue_bytes, []),
       due: System.monotonic_time(:millisecond)
     }}
  end

  @impl true
  def handle_info(:ready, s) do
    Event.emit(s.init, :channel, :ready, %{
      capabilities: capabilities(),
      format: s.init.audio_format
    })

    send(self(), :tick)
    {:noreply, s}
  end

  def handle_info(:tick, %{closed: true} = s), do: {:noreply, s}

  def handle_info(:tick, s) do
    count = min(480, byte_size(s.pending))
    <<pcm::binary-size(^count), rest::binary>> = s.pending
    pcm = pcm <> :binary.copy(<<0>>, 480 - count)

    if s.ambience && is_pid(s.recorder) && s.pending_label && count > 0 do
      BookingDesk.Recorder.mark(s.recorder, "input:caller_started", %{
        label: s.pending_label,
        tick: s.sequence,
        bytes: s.pending_bytes
      })
    end

    {pcm, ambience} = BookingDesk.Ambience.mix(s.ambience, pcm)
    frame = AudioFrame.pcm(pcm, s.init.adapter_id, s.sequence)

    input =
      case AudioQueue.push(s.input, frame) do
        {:ok, queue} -> queue
        _ -> s.input
      end

    {output, s} = output_tick(s)

    Parlora.AudioObserver.send_audio(s.observer, :input, pcm)
    Parlora.AudioObserver.send_audio(s.observer, :output, output)

    audible = audible?(output)

    if audible, do: send(s.owner, {:playout_active, System.monotonic_time(:millisecond)})
    due = s.due + 10
    Process.send_after(self(), :tick, max(0, due - System.monotonic_time(:millisecond)))

    {:noreply,
     %{
       s
       | input: input,
         pending: rest,
         pending_label: nil,
         ambience: ambience,
         sequence: s.sequence + 1,
         due: due
     }}
  end

  @impl true
  def handle_call(:capabilities, _, s), do: {:reply, {:ok, capabilities()}, s}

  def handle_call(:ambience_info, _, s), do: {:reply, BookingDesk.Ambience.info(s.ambience), s}

  def handle_call(:output_drained, _, s),
    do: {:reply, output_drained?(s.output) and not audible?(s.output_pcm), s}

  def handle_call({:read, budget}, _, s) do
    {frames, queue} = AudioQueue.pop(s.input, budget)
    {:reply, {:ok, frames}, %{s | input: queue}}
  end

  def handle_call({:write, frame}, _, s) do
    with :ok <- AudioFrame.validate(frame, s.init.audio_format, s.init.limits),
         true <- frame.playback_epoch == s.epoch,
         {:ok, queue} <- queue_output(s, frame) do
      {:reply, :ok,
       %{
         s
         | output: if(s.suppressed, do: s.output, else: queue),
           playout: Playout.observe(s.playout, frame)
       }}
    else
      false -> {:reply, Error.tuple(:invalid_argument, "Stale playback epoch"), s}
      error -> {:reply, error, s}
    end
  end

  def handle_call({:play, pcm, label}, _, s)
      when s.pending == <<>> and byte_size(pcm) <= 1_440_000,
      do: {:reply, :ok, %{s | pending: pcm, pending_label: label, pending_bytes: byte_size(pcm)}}

  def handle_call({:play, _, _}, _, s), do: {:reply, {:error, :busy}, s}

  def handle_call({:control, id, {:clear_output, epoch}}, _, s) when epoch > s.epoch do
    Event.emit(s.init, :channel, :control_completed, %{epoch: epoch, scope: :parlora_buffers},
      command_id: id
    )

    {:reply, :ok,
     %{
       s
       | output: AudioQueue.clear(s.output),
         output_pcm: <<>>,
         playout: Playout.reset(s.playout),
         epoch: epoch
     }}
  end

  def handle_call({:control, id, {:suppress_output, flag}}, _, s) do
    Event.emit(s.init, :channel, :control_completed, %{}, command_id: id)
    {:reply, :ok, %{s | suppressed: flag}}
  end

  def handle_call({:close, id, _}, _, s) do
    Event.emit(s.init, :channel, :closed, %{finalized?: true}, command_id: id)
    {:reply, :ok, %{s | closed: true}}
  end

  def capabilities, do: Capabilities.buffered_pcm()

  defp queue_output(s, frame) do
    if s.output.bytes + byte_size(s.output_pcm) + byte_size(frame.data) <= s.output.capacity,
      do: AudioQueue.push(s.output, frame),
      else: Error.tuple(:backpressure, "Audio queue is full")
  end

  defp output_tick(s) do
    s = fill_output(s, System.monotonic_time(:microsecond))
    size = min(480, byte_size(s.output_pcm))
    <<pcm::binary-size(^size), rest::binary>> = s.output_pcm
    {pcm <> :binary.copy(<<0>>, 480 - size), %{s | output_pcm: rest}}
  end

  # A network chunk can end inside a playback tick. Carry its remainder into
  # the next chunk instead of inserting silence at each network boundary.
  defp fill_output(%{output_pcm: pcm} = s, _now) when byte_size(pcm) >= 480, do: s

  defp fill_output(%{output_pcm: pcm, output: %{bytes: 0}} = s, _now)
       when byte_size(pcm) > 0,
       do: s

  defp fill_output(s, now) do
    {pcm, queue, playout} = Playout.take(s.playout, s.output, s.init.limits.max_frame_bytes, now)

    fill_output(%{s | output_pcm: s.output_pcm <> pcm, output: queue, playout: playout}, now)
  end

  defp audible?(pcm) do
    for <<sample::signed-little-16 <- pcm>>, reduce: false do
      loud -> loud or abs(sample) > 256
    end
  end
end
