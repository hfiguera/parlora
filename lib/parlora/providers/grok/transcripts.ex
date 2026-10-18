defmodule Parlora.Providers.Grok.Transcripts do
  @moduledoc false
  alias Parlora.Error

  # Live grok-transcribe emits cumulative completed events before commitment as
  # well as updated events. Neither may be concatenated into caller history.
  # Retain the latest candidate until the post-commit completed event; emit once.
  def new(limit), do: %{limit: limit, items: %{}}

  def observe(transcripts, %{"item_id" => id} = event) when is_binary(id) and id != "" do
    item = Map.get(transcripts.items, id, %{committed: false, emitted: false, text: ""})
    text = event["transcript"] || item.text

    with :ok <- valid_text(text),
         :ok <- capacity(transcripts, id),
         :ok <- unchanged(item, text) do
      finalize(transcripts, item, event, id, text)
    end
  end

  def observe(_transcripts, _event),
    do: Error.tuple(:invalid_argument, "Caller transcript requires an item ID")

  defp valid_text(text) when is_binary(text) and byte_size(text) <= 16_384, do: :ok
  defp valid_text(_text), do: Error.tuple(:backpressure, "Caller transcript exceeds its bound")

  defp capacity(transcripts, id) do
    if Map.has_key?(transcripts.items, id) or map_size(transcripts.items) < transcripts.limit,
      do: :ok,
      else: Error.tuple(:backpressure, "Caller transcript record capacity exhausted")
  end

  defp unchanged(%{emitted: true, text: old}, text) when old != text,
    do: Error.tuple(:adapter_failed, "Provider revised an already finalized caller transcript")

  defp unchanged(_item, _text), do: :ok

  defp finalize(transcripts, item, event, id, text) do
    commit = event["type"] == "input_audio_buffer.committed"
    completed = event["type"] == "conversation.item.input_audio_transcription.completed"
    emit? = item.committed and completed and not item.emitted and text != ""

    next = %{
      item
      | text: text,
        committed: item.committed or commit,
        emitted: item.emitted or emit?
    }

    caption =
      if emit?,
        do: %{
          speaker: :user,
          delta: text,
          start_ms: nil,
          end_ms: nil,
          timing: :unavailable,
          segment_id: id
        }

    {:ok, caption, %{transcripts | items: Map.put(transcripts.items, id, next)}}
  end
end
