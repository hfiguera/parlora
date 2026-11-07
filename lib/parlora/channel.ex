defmodule Parlora.Channel do
  @moduledoc "Participant audio and playback controls, independent of device or transport."
  use Parlora.AdapterBehaviour, capabilities: Parlora.Channel.Capabilities

  @callback read_audio(pid(), pos_integer()) ::
              {:ok, [Parlora.AudioFrame.t()]} | {:error, Parlora.Error.t()}
  @callback write_audio(pid(), Parlora.AudioFrame.t()) :: :ok | {:error, Parlora.Error.t()}
  @callback control(
              pid(),
              String.t(),
              {:suppress_output, boolean()} | {:clear_output, non_neg_integer()}
            ) :: :ok | {:error, Parlora.Error.t()}

  @doc "Optional, idempotent pressure hint: release recovery in this playback epoch only."
  @callback release_output_recovery(pid(), non_neg_integer()) :: :ok | {:error, Parlora.Error.t()}
  @optional_callbacks release_output_recovery: 2

  @doc "Optional one-shot hint when a frame fits the output queue in this playback epoch."
  @callback arm_output_space(pid(), pid(), reference(), pos_integer(), non_neg_integer()) ::
              :ok | {:error, Parlora.Error.t()}
  @optional_callbacks arm_output_space: 5

  @type playback_position ::
          %{stream_id: String.t(), played_ms: non_neg_integer()}
          | %{last_handed_off_sequence: non_neg_integer() | nil}
          | %{last_forwarded_sequence: non_neg_integer() | nil}
  @doc "Clear output and return the played position or the last frame handed to playback, when known."
  @callback clear_output_with_playback(pid(), String.t(), non_neg_integer()) ::
              {:ok, playback_position() | nil} | {:error, Parlora.Error.t()}
  @optional_callbacks clear_output_with_playback: 3
end
