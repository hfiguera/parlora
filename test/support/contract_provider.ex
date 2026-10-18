defmodule Parlora.TestSupport.ContractProvider do
  @moduledoc false
  @behaviour Parlora.Provider
  alias Parlora.{ContextUpdate, Error}
  alias Parlora.Provider.Capabilities
  alias Parlora.TestSupport.MemoryAudio

  # Deliberately narrower than OpenAI: caller transcripts and speakable updates,
  # without mute, usage, instruction/quiet updates or optional pressure callbacks.
  def profile(format) do
    %Capabilities{
      audio_formats: [format],
      full_duplex?: true,
      transcripts: [:user],
      delegation_modes: [:client],
      context_update_kinds: [:speakable]
    }
  end

  @impl true
  def start_link(init, options) do
    options = Keyword.put_new(options, :capabilities, profile(init.audio_format))
    MemoryAudio.start_link(init, :provider, options)
  end

  @impl true
  defdelegate capabilities(pid), to: MemoryAudio
  @impl true
  defdelegate read_audio(pid, budget), to: MemoryAudio
  @impl true
  defdelegate write_audio(pid, frame), to: MemoryAudio
  @impl true
  defdelegate close(pid, id, reason), to: MemoryAudio

  @impl true
  def append_context(pid, %ContextUpdate{kind: :speakable} = update),
    do: MemoryAudio.append_context(pid, update)

  def append_context(_pid, _update),
    do: Error.tuple(:unsupported, "Only speakable context is supported")

  @impl true
  def control(_pid, _id, _command),
    do: Error.tuple(:unsupported, "Provider controls are unsupported")
end
