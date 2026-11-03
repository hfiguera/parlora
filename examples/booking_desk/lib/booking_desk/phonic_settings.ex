defmodule BookingDesk.PhonicSettings do
  @moduledoc "Clinic recognition keywords; conversational defaults belong to Parlora."

  def options("phonic"), do: [boosted_keywords: ["Cedarwood", "Dr. Lee", "Dr. Patel"]]
  def options(_provider), do: []
end
