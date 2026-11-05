defmodule BookingDesk.PhonicSettings do
  @moduledoc "Clinic recognition and café-tested speech detection; other defaults belong to Parlora."

  def options("phonic"),
    do: [boosted_keywords: ["Cedarwood", "Dr. Lee", "Dr. Patel"], vad_threshold: 0.8]

  def options(_provider), do: []
end
