defmodule BookingDesk.PhonicSettings do
  @moduledoc "Clinic recognition, café-tested speech detection, and Phonic tool timing."

  def options("phonic"),
    do: [
      boosted_keywords: ["Cedarwood", "Dr. Lee", "Dr. Patel"],
      vad_threshold: 0.8,
      wait_for_speech_before_tool_call: true
    ]

  def options(_provider), do: []
end
