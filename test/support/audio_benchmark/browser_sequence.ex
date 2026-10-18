defmodule Parlora.TestSupport.AudioBenchmark.BrowserSequence do
  @moduledoc false
  import ExUnit.Assertions
  alias Parlora.{AdapterInit, AudioFormat, AudioFrame, CommandLog, Error, Limits}
  alias Parlora.Channels.Browser
  alias Parlora.Channels.Browser.Media
  alias Parlora.Native.Opus
  alias Parlora.TestSupport.AudioBenchmark.Generators

  def run(commands) do
    init = %AdapterInit{
      session_id: "property",
      adapter_id: "browser",
      generation: 0,
      audio_format: %AudioFormat{},
      limits: %Limits{},
      event_sink: self()
    }

    options = %{
      jitter_ms: 0,
      max_rtp_packets: 32,
      max_age_ms: 200,
      playback_buffer_ms: 120,
      playback_buffering: :adaptive,
      playback_recovery_ms: 120
    }

    media = Media.open(init, options)
    reference = Media.open(init, options)
    state = %{init: init, media: media, status: :ready, commands: %CommandLog{limit: 256}}
    model = %{pending: <<>>, stopped: false, epoch: 0, clock: 0, reference: reference.encoder}

    try do
      {state, model} =
        commands
        |> Stream.with_index()
        |> Enum.reduce({state, model}, fn {command, id}, {state, model} ->
          {next, expected} = step(command, id, state, model)
          assert next.media.outbound.bytes <= 9_600
          assert byte_size(next.media.output_pcm) < init.limits.max_frame_bytes

          assert byte_size(expected.pending) ==
                   next.media.outbound.bytes + byte_size(next.media.output_pcm)

          queued = next.media.outbound.items |> :queue.to_list() |> Enum.map_join(& &1.data)
          assert expected.pending == next.media.output_pcm <> queued

          {next, expected}
        end)

      {_state, model} = tick(state, model, 50)
      assert model.pending == <<>>
    after
      Media.close(media)
      Media.close(reference)
      flush_events()
      assert {:error, :closed_or_wrong_kind} = Opus.reset(media.encoder)
      assert {:error, :closed_or_wrong_kind} = Opus.reset(media.decoder)
      assert {:error, :closed_or_wrong_kind} = Opus.reset(reference.encoder)
    end
  end

  defp step({:write, samples}, id, state, model) do
    data = Generators.pcm(samples, id * 480, false)
    frame = AudioFrame.pcm(data, "property", id, playback_epoch: model.epoch)

    case Browser.handle_call({:write, frame}, nil, state) do
      {:reply, :ok, next} ->
        pending = if model.stopped, do: model.pending, else: model.pending <> data
        {next, %{model | pending: pending}}

      {:reply, {:error, %Error{code: :backpressure}}, next} ->
        assert next == state
        assert state.media.outbound.bytes + byte_size(data) > 9_600
        {next, model}
    end
  end

  defp step({:tick, count}, _id, state, model), do: tick(state, model, count)

  defp step(:stale, id, state, model) do
    frame = AudioFrame.pcm(<<1, 0>>, "old", id, playback_epoch: model.epoch - 1)

    assert {:reply, {:error, %Error{code: :invalid_argument}}, ^state} =
             Browser.handle_call({:write, frame}, nil, state)

    {state, model}
  end

  defp step(command, id, state, model) do
    {control, expected} = control(command, model)
    {:reply, :ok, next} = Browser.handle_call({:control, "control-#{id}", control}, nil, state)
    :ok = Opus.reset(model.reference)
    assert next.media.outbound.bytes == 0
    assert next.media.output_pcm == <<>>
    {next, %{expected | pending: <<>>}}
  end

  defp control(:clear, model),
    do: {{:clear_output, model.epoch + 1}, %{model | epoch: model.epoch + 1}}

  defp control(:stop, model), do: {{:suppress_output, true}, %{model | stopped: true}}
  defp control(:resume, model), do: {{:suppress_output, false}, %{model | stopped: false}}

  defp tick(state, model, count) do
    Enum.reduce(1..count, {state, model}, fn _i, {state, model} ->
      {packet, next} = Media.output(state, model.clock)
      {pcm, pending} = expected_pcm(next.media.output_source?, model)
      {:ok, encoded} = Opus.encode(model.reference, pcm, 240)
      assert packet.payload == encoded
      {next, %{model | pending: pending, clock: model.clock + 10_000}}
    end)
  end

  # Timing decisions come from the implementation; the byte stream oracle does
  # not. Every source packet must match the next accepted, uncleared samples.
  # The final bounded drain separately rejects implementations that never play.
  defp expected_pcm(true, model) do
    refute model.stopped
    assert byte_size(model.pending) > 0
    bytes = min(480, byte_size(model.pending))
    <<pcm::binary-size(^bytes), rest::binary>> = model.pending
    {pcm <> :binary.copy(<<0>>, 480 - bytes), rest}
  end

  defp expected_pcm(false, model), do: {:binary.copy(<<0>>, 480), model.pending}

  defp flush_events do
    receive do
      {:parlora_event, _event} -> flush_events()
    after
      0 -> :ok
    end
  end
end
