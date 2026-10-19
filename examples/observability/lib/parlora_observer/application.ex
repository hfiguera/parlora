defmodule ParloraObserver.Application do
  use Application
  @impl true
  def start(_type, _args) do
    children = [
      {TelemetryMetricsPrometheus.Core, metrics: metrics()},
      ParloraObserver.Traces,
      {Bandit,
       plug: ParloraObserver.Metrics,
       ip: {0, 0, 0, 0},
       port: Application.fetch_env!(:parlora_observer, :metrics_port)}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  defp metrics do
    operations = [
      :session,
      :startup,
      :shutdown,
      :policy,
      :backend_queue,
      :backend,
      :delivery,
      :recovery,
      :interruption
    ]

    Enum.flat_map(operations, fn operation ->
      [
        Telemetry.Metrics.counter("parlora.#{operation}.stop.count", tags: [:outcome]),
        Telemetry.Metrics.distribution("parlora.#{operation}.stop.duration_seconds",
          event_name: [:parlora, operation, :stop],
          measurement: :duration,
          description: "Observed #{operation} duration in seconds.",
          unit: {:native, :second},
          tags: [:outcome],
          reporter_options: [buckets: [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 5, 15]]
        )
      ]
    end) ++
      [
        # Distributions pool observations across sessions; a global last value would
        # show whichever session happened to emit most recently.
        Telemetry.Metrics.distribution("parlora.provider.audio_received.queue_bytes",
          description: "Provider queue size at receive observations, in bytes.",
          reporter_options: [buckets: [0, 480, 4800, 9600, 48000, 480_000]]
        ),
        Telemetry.Metrics.distribution("parlora.provider.audio_received.queue_duration_seconds",
          event_name: [:parlora, :provider, :audio_received],
          measurement: :queue_duration_us,
          description: "Provider queue duration at receive observations, in seconds.",
          unit: {:microsecond, :second},
          reporter_options: [buckets: [0, 0.01, 0.05, 0.1, 0.12, 0.2, 0.5, 1, 5, 10]]
        ),
        Telemetry.Metrics.distribution("parlora.provider.audio_read.oldest_age_seconds",
          event_name: [:parlora, :provider, :audio_read],
          measurement: :oldest_age_us,
          description: "Oldest queued audio age at read observations, in seconds.",
          unit: {:microsecond, :second},
          reporter_options: [buckets: [0, 0.01, 0.05, 0.1, 0.2, 0.5, 1, 5, 10]]
        ),
        Telemetry.Metrics.sum("parlora.provider.audio_received.dropped_bytes",
          description: "Bytes rejected at the provider output queue."
        ),
        Telemetry.Metrics.distribution("parlora.audio.playout.target_seconds",
          event_name: [:parlora, :audio, :playout],
          measurement: :playback_target_ms,
          unit: {:millisecond, :second},
          tags: [:channel],
          description: "Playback buffer target observations, in seconds.",
          reporter_options: [buckets: [0.12, 0.2, 0.25, 0.3, 0.5, 1]]
        ),
        Telemetry.Metrics.distribution("parlora.audio.tick.late_seconds",
          event_name: [:parlora, :audio, :tick],
          measurement: :late_us,
          unit: {:microsecond, :second},
          tags: [:direction],
          description: "Audio tick scheduling lateness, in seconds.",
          reporter_options: [buckets: [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25]]
        ),
        Telemetry.Metrics.counter("parlora.runtime.event.count",
          tags: [:source, :type, :stage],
          tag_values: &Map.put_new(&1, :stage, :none),
          description: "Operational observations, grouped by source, type and optional stage."
        )
      ]
  end
end
