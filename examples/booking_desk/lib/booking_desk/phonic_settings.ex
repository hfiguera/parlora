defmodule BookingDesk.PhonicSettings do
  @moduledoc "Default native conversation profile for the booking example's Phonic sessions."

  def options(provider, enabled \\ true)

  def options("phonic", true) do
    [
      enable_assistant_backchannel: true,
      assistant_backchannel_aggressiveness: 0.3,
      require_speech_before_tool_call: true,
      wait_for_speech_before_tool_call: false,
      wait_for_response: true,
      tool_timeout_ms: 60_000,
      audio_speed: 1.05,
      vad_min_silence_duration_ms: 600,
      min_words_to_interrupt: 1,
      boosted_keywords: ["Cedarwood", "Dr. Lee", "Dr. Patel"]
    ]
  end

  def options(_provider, _enabled), do: []
end
