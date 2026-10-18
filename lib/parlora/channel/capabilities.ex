defmodule Parlora.Channel.Capabilities do
  @moduledoc "Effective channel formats, controls, and sources of playback evidence."
  @type pacing :: :pipeline | :channel
  @type clear_scope :: :none | :parlora_buffers | :remote_buffer
  @type evidence :: :queue | :handoff | :estimated_device_time | :device_report
  @type t :: %__MODULE__{
          input_formats: [Parlora.AudioFormat.t()],
          output_formats: [Parlora.AudioFormat.t()],
          full_duplex?: boolean(),
          output_pacing: pacing(),
          output_suppression?: boolean(),
          clear_scope: clear_scope(),
          playback_evidence: [evidence()]
        }
  defstruct input_formats: [],
            output_formats: [],
            full_duplex?: false,
            output_pacing: :pipeline,
            output_suppression?: false,
            clear_scope: :none,
            playback_evidence: []

  @doc "PCM duplex with local queue clearing and admission/handoff observations."
  def buffered_pcm do
    %__MODULE__{
      input_formats: [%Parlora.AudioFormat{}],
      output_formats: [%Parlora.AudioFormat{}],
      full_duplex?: true,
      output_suppression?: true,
      clear_scope: :parlora_buffers,
      playback_evidence: [:queue, :handoff]
    }
  end
end
