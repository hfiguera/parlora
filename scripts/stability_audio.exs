Code.require_file("support/stability.ex", __DIR__)

defmodule Parlora.AudioStability do
  alias Parlora.{AdapterInit, AudioFrame, Event, ID, Limits, Pacer}
  alias Parlora.Channels.LocalAudio
  alias Parlora.Validation.Stability

  def run do
    seconds = Stability.integer_env("PARLORA_AUDIO_SECONDS", 60, 600)
    cycles = Stability.integer_env("PARLORA_AUDIO_CYCLES", 3, 20)
    host = System.fetch_env!("CPAL_HOST")
    {:ok, devices} = LocalAudio.devices(host)

    options = [
      host: host,
      input_device: device(devices, "CPAL_INPUT", :input),
      output_device: device(devices, "CPAL_OUTPUT", :output)
    ]

    before = Stability.vm_sample()
    results = Enum.map(1..cycles, fn cycle -> run_cycle(options, seconds, cycle) end)

    Stability.report(:audio_summary, %{
      before: before,
      after: Stability.vm_sample(),
      cycles: results
    })
  end

  defp device(devices, env, direction) do
    name = System.fetch_env!(env)

    device =
      Enum.find(devices, &(&1.name == name and Map.fetch!(&1, direction) != nil)) ||
        raise "Device unavailable"

    device.id
  end

  defp run_cycle(options, seconds, cycle) do
    init = %AdapterInit{
      session_id: ID.new(),
      adapter_id: ID.new(),
      generation: 0,
      event_sink: self(),
      audio_format: %Parlora.AudioFormat{},
      limits: %Limits{}
    }

    {:ok, pid} = LocalAudio.start_link(init, options)

    receive do
      {:parlora_event, %Event{type: :ready}} -> :ok
    after
      10_000 -> raise "Audio readiness timeout"
    end

    try do
      # Drain continuously during warmup; metrics exclude startup drops.
      warm =
        stream(pid, 100, %{
          epoch: 0,
          peaks: %{},
          clears: [],
          deadline: System.monotonic_time(:microsecond)
        })

      baseline = LocalAudio.observations(pid)
      result = stream(pid, seconds * 100, warm)
      final = LocalAudio.observations(pid)
      {close_us, :ok} = :timer.tc(fn -> close(pid) end)

      summary = %{
        cycle: cycle,
        seconds: seconds,
        peaks: result.peaks,
        clear_us: result.clears,
        close_us: close_us,
        dropped_after_warmup: final.dropped - baseline.dropped,
        underrun_after_warmup: final.underrun - baseline.underrun,
        device_errors: final.errors,
        handed_off: final.handed_off - baseline.handed_off,
        max_poll_gap_us: final.max_poll_gap_us,
        input_ppm: final.input_ppm,
        output_ppm: final.output_ppm
      }

      Stability.report(:audio_cycle, summary)

      if final.errors != 0 or final.dropped != baseline.dropped,
        do: raise("Audio error or steady-state capture drops")

      if final.handed_off <= baseline.handed_off, do: raise("No device handoff")
      summary
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
      drain_events()
    end
  end

  defp stream(pid, blocks, initial) do
    Enum.reduce(1..blocks, initial, fn index, state ->
      state = if rem(index, 1_500) == 0, do: clear_resume(pid, state), else: state

      pcm =
        for sample <- 0..239, into: <<>> do
          value = round(300 * :math.sin(2 * :math.pi() * 440 * sample / 24_000))
          <<value::signed-little-16>>
        end

      :ok =
        LocalAudio.write_audio(
          pid,
          AudioFrame.pcm(pcm, "stability", index, playback_epoch: state.epoch)
        )

      {:ok, _discarded_frames} = LocalAudio.read_audio(pid, 9_600)
      drain_events()
      state = if rem(index, 100) == 0, do: sample(pid, state), else: state
      {deadline, delay} = Pacer.next(state.deadline, 10_000)
      Process.sleep(delay)
      %{state | deadline: deadline}
    end)
  end

  defp sample(pid, state) do
    stats = LocalAudio.observations(pid)
    queues = Map.take(stats, [:input_queued, :output_queued])

    if Enum.any?(queues, fn {_key, count} -> count > 4_800 end),
      do: raise("Native queue exceeded capacity")

    sample = Map.merge(queues, Stability.process_sample([pid, self()]))
    %{state | peaks: Stability.peaks(state.peaks, sample)}
  end

  defp clear_resume(pid, state) do
    epoch = state.epoch + 1
    :ok = LocalAudio.control(pid, ID.new(), {:suppress_output, true})
    {us, :ok} = :timer.tc(fn -> LocalAudio.control(pid, ID.new(), {:clear_output, epoch}) end)
    if LocalAudio.observations(pid).observed_epoch != epoch, do: raise("Clear epoch unconfirmed")
    :ok = LocalAudio.control(pid, ID.new(), {:suppress_output, false})
    %{state | epoch: epoch, clears: [us | state.clears]}
  end

  defp close(pid) do
    :ok = LocalAudio.close(pid, ID.new(), :stability)

    receive do
      {:parlora_event, %Event{type: :closed}} -> :ok
    after
      5_000 -> raise "Audio close timeout"
    end
  end

  defp drain_events do
    receive do
      {:parlora_event, %Event{type: :failed}} -> raise "Audio failed"
      {:parlora_event, _event} -> drain_events()
    after
      0 -> :ok
    end
  end
end

Parlora.AudioStability.run()
