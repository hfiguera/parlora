defmodule BookingDesk.GrokSettings do
  @moduledoc "Booking-specific Grok pacing and clinic vocabulary; callers may override each option."

  def voice, do: "ara"

  def options do
    [
      language_hint: "en",
      keyterms: ["Cedarwood", "Dr. Lee", "Dr. Patel"],
      speed: 1.0,
      idle_timeout_ms: nil,
      replace: %{},
      reasoning_effort: :high
    ]
  end
end
