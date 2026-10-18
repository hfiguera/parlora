defmodule Parlora.Provider do
  @moduledoc """
  Continuous full-duplex voice, client delegation and correlated context updates.

  The current session coordinator requires the selected `AudioFormat` in
  `Capabilities.audio_formats`, `full_duplex?: true`, `:client` in
  `delegation_modes`, and `:speakable` in `context_update_kinds`. It rejects an
  incompatible ready provider with `:unsupported` and closes the session before
  starting the audio pipelines. Process startup alone does not imply readiness.

  This is a contract for this voice architecture, not a universal STT/LLM/TTS or
  turn-based model interface. Another implementation must translate its behavior
  into these semantics; implementing the callbacks alone is insufficient.

  Quiet/instruction updates, mute, usage and transcript speakers are declared
  capabilities, not startup requirements. The application policy must have enough
  context to interpret delegations; the coordinator does not infer task arguments
  or invent missing transcripts. Unsupported commands return `:unsupported`.
  `output_buffer_status/1` and `arm_output_ready/3` are optional. The selected pipeline format is used in
  both directions even when a provider can support different formats internally.

  Context admission, provider acknowledgment, backend completion and playback
  evidence remain separate. A provider must preserve command correlation without
  promising that the caller heard an acknowledged context update.
  """
  use Parlora.AdapterBehaviour, capabilities: Parlora.Provider.Capabilities

  @callback read_audio(pid(), pos_integer()) ::
              {:ok, [Parlora.AudioFrame.t()]} | {:error, Parlora.Error.t()}
  @callback write_audio(pid(), Parlora.AudioFrame.t()) :: :ok | {:error, Parlora.Error.t()}
  @callback append_context(pid(), Parlora.ContextUpdate.t()) :: :ok | {:error, Parlora.Error.t()}
  @callback control(pid(), String.t(), {:input_muted, boolean()}) ::
              :ok | {:error, Parlora.Error.t()}

  @doc "Optional snapshot of generated audio waiting for the output pipeline, in bytes."
  @callback output_buffer_status(pid()) ::
              {:ok, %{queued_bytes: non_neg_integer(), capacity_bytes: pos_integer()}}
              | {:error, Parlora.Error.t()}
  @doc """
  Arm a one-shot generated-audio notification for a single output reader.

  Send `{:parlora_audio_ready, provider_pid, reference}` to `reader` when audio
  is available, including when it was queued before this call. A new arm replaces
  the previous one. Successful nonempty reads and close retire the arm. It is a
  scheduling hint, not an audio frame or playback evidence. Implementations keep
  at most one arm and send at most one notification per arm.
  """
  @callback arm_output_ready(pid(), pid(), reference()) :: :ok | {:error, Parlora.Error.t()}
  @doc "Release new output after the coordinator cleared interrupted playback."
  @callback resume_output(pid(), non_neg_integer()) :: :ok | {:error, Parlora.Error.t()}
  @doc "Resolve a provider function call that was associated, rejected, or superseded without a new result."
  @callback resolve_delegation(pid(), String.t(), map()) :: :ok | {:error, Parlora.Error.t()}
  @doc "Provider receive-storage defaults, independent of the playback cushion. Explicit session limits override them."
  @callback audio_limits(Parlora.AudioFormat.t()) :: keyword()
  @doc "Replace an overloaded voice transport after the coordinator cleared its playback. Preserve backend execution and logical provider generation."
  @callback recover_output(pid(), pos_integer(), Parlora.ContextSnapshot.t()) ::
              :ok | {:error, Parlora.Error.t()}
  @optional_callbacks audio_limits: 1,
                      recover_output: 3,
                      output_buffer_status: 1,
                      arm_output_ready: 3,
                      resume_output: 2,
                      resolve_delegation: 3
end
