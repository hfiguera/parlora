defmodule OrderDesk.ScriptedProvider do
  @moduledoc "Bounded offline provider for consumer checks, not a voice model."
  use GenServer
  @behaviour Parlora.Provider
  alias Parlora.{AudioFormat, AudioFrame, Event}

  @impl true
  def start_link(init, options), do: GenServer.start_link(__MODULE__, {init, options})
  @impl true
  def capabilities(pid), do: GenServer.call(pid, :capabilities)
  @impl true
  def read_audio(pid, budget), do: GenServer.call(pid, {:read, budget})
  @impl true
  def write_audio(pid, frame), do: GenServer.call(pid, {:write, frame})
  @impl true
  def append_context(pid, update), do: GenServer.call(pid, {:context, update})
  @impl true
  def control(pid, id, command), do: GenServer.call(pid, {:control, id, command})
  @impl true
  def close(pid, id, reason), do: GenServer.call(pid, {:close, id, reason})

  def say(pid, text), do: GenServer.call(pid, {:say, text})
  def transcript(pid, fragment), do: GenServer.call(pid, {:transcript, fragment})
  def delegate(pid, id), do: GenServer.call(pid, {:delegate, id})
  def audio(pid, enabled), do: GenServer.call(pid, {:audio, enabled})
  def capture_bytes(pid), do: GenServer.call(pid, :capture_bytes)

  @impl true
  def init({init, options}) do
    observer = Keyword.fetch!(options, :observer)
    send(observer, {:scripted_provider, self()})
    Event.emit(init, :provider, :ready, %{capabilities: caps(), format: %AudioFormat{}})

    tone =
      for n <- 0..2399, into: <<>> do
        sample = round(100 * :math.sin(2 * :math.pi() * 440 * n / 24_000))
        <<sample::signed-little-16>>
      end

    {:ok,
     %{
       init: init,
       observer: observer,
       sequence: 0,
       capture_bytes: 0,
       commands: MapSet.new(),
       audio?: Keyword.get(options, :audio, true),
       tone: tone
     }}
  end

  @impl true
  def handle_call(:capabilities, _from, state), do: {:reply, {:ok, caps()}, state}
  def handle_call(:capture_bytes, _from, state), do: {:reply, state.capture_bytes, state}

  def handle_call({:audio, enabled}, _from, state) when is_boolean(enabled),
    do: {:reply, :ok, %{state | audio?: enabled}}

  def handle_call({:read, _budget}, _from, %{audio?: false} = state),
    do: {:reply, {:ok, []}, state}

  # One 10 ms frame per poll; no unbounded producer or audio storage.
  def handle_call({:read, budget}, _from, state) when budget >= 480 do
    pcm = binary_part(state.tone, rem(state.sequence, 10) * 480, 480)
    frame = AudioFrame.pcm(pcm, "consumer-provider", state.sequence)
    {:reply, {:ok, [frame]}, %{state | sequence: state.sequence + 1}}
  end

  def handle_call({:write, frame}, _from, state),
    do: {:reply, :ok, %{state | capture_bytes: state.capture_bytes + byte_size(frame.data)}}

  def handle_call({:say, text}, _from, state) do
    Event.emit(state.init, :provider, :transcript_delta, %{
      speaker: :user,
      delta: text,
      start_ms: 0,
      end_ms: 100
    })

    {:reply, :ok, state}
  end

  def handle_call({:transcript, fragment}, _from, state) do
    Event.emit(state.init, :provider, :transcript_delta, fragment)
    {:reply, :ok, state}
  end

  def handle_call({:delegate, id}, _from, state) do
    Event.emit(state.init, :provider, :delegation_requested, %{
      id: id,
      offset_ms: 50,
      target: :client
    })

    {:reply, :ok, state}
  end

  def handle_call({:context, update}, _from, state) do
    if MapSet.member?(state.commands, update.id) do
      {:reply, :ok, state}
    else
      if MapSet.size(state.commands) < state.init.limits.max_records do
        send(state.observer, {:context, update})
        Event.emit(state.init, :provider, :context_acknowledged, %{}, command_id: update.id)
        {:reply, :ok, %{state | commands: MapSet.put(state.commands, update.id)}}
      else
        {:reply,
         {:error, %Parlora.Error{code: :backpressure, message: "Context capacity exhausted"}},
         state}
      end
    end
  end

  def handle_call({:control, id, _command}, _from, state) do
    Event.emit(state.init, :provider, :control_completed, %{}, command_id: id)
    {:reply, :ok, state}
  end

  def handle_call({:close, id, _reason}, _from, state) do
    Event.emit(state.init, :provider, :closed, %{finalized?: true}, command_id: id)
    {:reply, :ok, state}
  end

  defp caps do
    %Parlora.Provider.Capabilities{
      audio_formats: [%AudioFormat{}],
      full_duplex?: true,
      transcripts: [:user, :assistant],
      delegation_modes: [:client],
      context_update_kinds: [:quiet, :speakable, :instruction],
      input_mute?: true
    }
  end
end
