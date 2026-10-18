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
end
