# A/B policy substitution is confined to this dedicated validation VM on 4002.
if System.get_env("AUDIO_POLICY") == "immediate" do
  Code.require_file("policies.exs", __DIR__)
  Code.compiler_options(ignore_module_conflict: true)

  Code.compile_string("""
  defmodule Parlora.Playout do
    defdelegate new(ms, capacity), to: ImmediatePlayout
    def new(ms, capacity, _options), do: new(ms, capacity)
    def valid_options?(ms, capacity, _options), do: is_integer(ms) and ms in 0..200 and ms * 48 <= capacity
    def observe(state, _frame), do: state
    def reset_timing(state), do: state
    def snapshot(state), do: %{playback_buffering: :fixed, playback_buffer_ms: state.buffer_ms,
      playback_target_ms: state.buffer_ms, recovery_buffer_ms: 0}
    defdelegate reset(state), to: Parlora.TestSupport.RecordedPlayout
    defdelegate release_recovery(state), to: ImmediatePlayout
    defdelegate take(state, queue, budget, now), to: ImmediatePlayout
    def recovery_wait_us(_state), do: 0
    def wait_limit_us(_state, _now), do: 0
  end
  """)
end

Code.require_file("../../scripts/audio_benchmark_server.exs", __DIR__)
