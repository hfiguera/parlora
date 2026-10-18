defmodule Parlora.Provider.Capabilities do
  @moduledoc """
  Effective voice-provider features; advertise only implemented behavior.

  See `Parlora.Provider` for the coordinator's required format, full-duplex,
  client-delegation and speakable-context profile. The other fields describe
  optional features. `same_format_both_directions?` declares a provider restriction;
  false does not request separate pipeline formats or enable format negotiation.
  """
  @type t :: %__MODULE__{
          audio_formats: [Parlora.AudioFormat.t()],
          same_format_both_directions?: boolean(),
          full_duplex?: boolean(),
          transcripts: [Parlora.ContextSnapshot.speaker()],
          delegation_modes: [:client],
          context_update_kinds: [Parlora.ContextUpdate.kind()],
          input_mute?: boolean(),
          usage?: boolean(),
          context_acknowledgment?: boolean()
        }
  defstruct audio_formats: [],
            same_format_both_directions?: true,
            full_duplex?: false,
            transcripts: [],
            delegation_modes: [],
            context_update_kinds: [],
            input_mute?: false,
            usage?: false,
            context_acknowledgment?: false
end
