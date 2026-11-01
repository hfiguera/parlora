import Config
import_config "../../observability/config/config.exs"
config :parlora, native_audio: true

if :os.type() == {:unix, :darwin},
  do: config(:bundlex, :disable_precompiled_os_deps, apps: [:ex_libsrtp])

config :booking_desk,
  database:
    if(config_env() == :test,
      do: ":memory:",
      else: System.get_env("BOOKING_DATABASE", "data/bookings.sqlite3")
    ),
  jev_model: "jev-1.13.0",
  identity_model: "openai:gpt-6-luna",
  delays: %{"2026-11-04" => 25_000, "2026-11-05" => 1_200, "booking" => 5_000}

config :logger, :default_handler, level: :warning
