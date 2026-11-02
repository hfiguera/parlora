defmodule BookingDesk.PhonicSettings do
  @moduledoc "Clinic keywords and an explicit manual-response comparison mode."

  def options(provider, enabled \\ true)

  def options("phonic", true), do: [boosted_keywords: ["Cedarwood", "Dr. Lee", "Dr. Patel"]]

  def options("phonic", false),
    do:
      Keyword.merge(options("phonic", true),
        enable_assistant_backchannel: false,
        require_speech_before_tool_call: false,
        wait_for_response: false
      )

  def options(_provider, _enabled), do: []
end
