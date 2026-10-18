import Config

# Host-owned compile-time configuration; native audio remains enabled.
config :parlora, native_audio: true

# Use Homebrew SRTP with its own OpenSSL paths on macOS.
if :os.type() == {:unix, :darwin} do
  config :bundlex, :disable_precompiled_os_deps, apps: [:ex_libsrtp]
end

config :order_desk,
       :database,
       if(config_env() == :test, do: ":memory:", else: "data/orders.sqlite3")
