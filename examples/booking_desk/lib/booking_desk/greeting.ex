defmodule BookingDesk.Greeting do
  @moduledoc "Live inbound-call opening and a software-playout milestone for the scripted caller."
  alias Parlora.ContextUpdate

  def update(generation) do
    %ContextUpdate{
      id: "booking-greeting-#{System.unique_integer([:positive])}",
      kind: :speakable,
      provider_generation: generation,
      content:
        "The inbound call has just connected. Greet the caller once as Ava at Cedarwood Family Clinic " <>
          "and ask how you can help. Keep it to one short greeting, then wait for the caller. " <>
          "The caller has not spoken yet and has not requested any scheduling work."
    }
  end

  def ready?(%{
        heard_audio: true,
        output_drained: true,
        text: text,
        speech: speech,
        quiet_ms: quiet
      })
      when is_binary(text) and is_integer(quiet) do
    String.trim(text) != "" and speech != :speaking and quiet >= 1_000
  end

  def ready?(_), do: false
end
