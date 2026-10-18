import Config

config :credence, assumptions: :strict

if config_env() == :test do
  # Keep startup/late teardown chatter off the console without filtering the
  # debug/info diagnostics collected by ExUnit for failing tests.
  config :logger, :default_handler, level: :warning
end

# Homebrew's system SRTP carries the correct OpenSSL dependency paths.
if :os.type() == {:unix, :darwin} do
  config :bundlex, :disable_precompiled_os_deps, apps: [:ex_libsrtp]
end
