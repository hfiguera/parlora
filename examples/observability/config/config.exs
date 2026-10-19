import Config

# Host-owned configuration. The deterministic demo uses no native devices/codecs.
config :parlora, native_audio: false, native_opus: false
config :opentelemetry, resource: [service: [name: "parlora-observability-demo"]]

config :opentelemetry, :processors,
  otel_batch_processor: %{
    scheduled_delay_ms: 1_000,
    max_queue_size: 512,
    max_export_batch_size: 64,
    exporter:
      {:opentelemetry_exporter,
       %{protocol: :http_protobuf, endpoints: ["http://127.0.0.1:14318"]}}
  }

config :logger, :default_handler, level: :warning

config :parlora_observer, metrics_port: if(config_env() == :test, do: 0, else: 19100)

if config_env() == :test do
  # Hermetic tests never export traces, even if the developer's stack is running.
  config :opentelemetry, traces_exporter: :none, processors: []
end
