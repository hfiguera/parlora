import Config

profile =
  case System.get_env("PARLORA_OPTIONAL_BACKEND", "none") do
    "none" -> :none
    "jido" -> :jido
    "sagents" -> :sagents
    "legion" -> :legion
  end

config :optional_backend_consumer, :profile, profile
config :parlora, native_audio: false, native_opus: false
config :logger, :default_handler, level: :warning

if :os.type() == {:unix, :darwin} do
  config :bundlex, :disable_precompiled_os_deps, apps: [:ex_libsrtp]
end
