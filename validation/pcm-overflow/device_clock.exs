alias Parlora.{AdapterInit, AudioFormat, Limits}
alias Parlora.Channels.LocalAudio

init = %AdapterInit{
  session_id: "clock-probe",
  adapter_id: "synthetic",
  generation: 0,
  event_sink: self(),
  audio_format: %AudioFormat{},
  limits: %Limits{}
}

{:ok, channel} = LocalAudio.start_link(init, device: :synthetic)

receive do
  {:parlora_event, %{type: :ready}} -> :ok
after
  5_000 -> raise "Native device did not start"
end

before = LocalAudio.observations(channel)
started = System.monotonic_time(:microsecond)
Process.sleep(3_000)
after_stats = LocalAudio.observations(channel)
elapsed = System.monotonic_time(:microsecond) - started

IO.puts(
  Jason.encode!(
    %{
      elapsed_us: elapsed,
      before: before,
      after: after_stats,
      rendered_audio_ms:
        (after_stats.rendered - before.rendered) / after_stats.output_rate * 1_000,
      rendered_ratio:
        (after_stats.rendered - before.rendered) / after_stats.output_rate / (elapsed / 1_000_000)
    },
    pretty: true
  )
)

:ok = LocalAudio.close(channel, "close", :cancel)
