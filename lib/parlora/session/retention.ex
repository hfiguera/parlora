defmodule Parlora.Session.Retention do
  @moduledoc false
  alias Parlora.Error
  alias Parlora.Session.State

  def append_transcript(state, payload) do
    entry =
      Map.merge(payload, %{
        provider_generation: state.context.provider_generation,
        arrival_order: state.context.revision
      })

    bytes = :erlang.external_size(entry)
    history = state.context.transcript_retention

    cond do
      bytes > state.limits.max_transcript_bytes ->
        exhausted(state, :entry_bytes)

      history.mode == :close and
          (history.retained + 1 > state.limits.max_transcripts or
             history.retained_bytes + bytes > state.limits.max_transcript_bytes) ->
        exhausted(state, :history)

      true ->
        history = %{
          history
          | retained: history.retained + 1,
            retained_bytes: history.retained_bytes + bytes
        }

        {entries, history} = retain(state, [entry | state.context.transcripts], history)
        context = %{state.context | transcripts: entries, transcript_retention: history}
        {:ok, State.revise(state, context)}
    end
  end

  def snapshot(state) do
    %{
      transcripts:
        Map.merge(state.context.transcript_retention, %{
          max_entries: state.limits.max_transcripts,
          max_bytes: state.limits.max_transcript_bytes
        }),
      records: %{
        retention: :session,
        limit: state.limits.max_records,
        jobs: map_size(state.jobs),
        tasks: map_size(state.context.tasks),
        delegations: map_size(state.context.pending_delegations),
        cancellations: map_size(state.cancellations),
        clarifications: MapSet.size(state.clarifications),
        progress_commands: map_size(state.health.commands.entries)
      }
    }
  end

  def record_limit(state, resource, message, retained) do
    Error.tuple(:backpressure, message, %{
      resource: resource,
      retention: :session,
      retained: retained,
      limit: state.limits.max_records
    })
  end

  defp exhausted(state, resource) do
    Error.tuple(:backpressure, "Transcript capacity exhausted", %{
      resource: resource,
      max_transcripts: state.limits.max_transcripts,
      max_transcript_bytes: state.limits.max_transcript_bytes
    })
  end

  defp retain(state, entries, history) do
    if history.retained <= state.limits.max_transcripts and
         history.retained_bytes <= state.limits.max_transcript_bytes do
      {entries, history}
    else
      # Leave headroom so count-based compaction is amortized across many deltas.
      count_limit = max(1, div(state.limits.max_transcripts * 3, 4))
      byte_limit = max(1, div(state.limits.max_transcript_bytes * 3, 4))
      {entries, count, bytes, revision} = keep(entries, count_limit, byte_limit, [], 0, 0)

      history = %{
        history
        | retained: count,
          retained_bytes: bytes,
          dropped: history.dropped + history.retained - count,
          dropped_bytes: history.dropped_bytes + history.retained_bytes - bytes,
          dropped_through_revision: revision
      }

      State.emit(state, :transcripts_compacted, history)
      {entries, history}
    end
  end

  defp keep([entry | rest], count_limit, byte_limit, acc, count, bytes) do
    next_bytes = bytes + :erlang.external_size(entry)

    if count > 0 and (count >= count_limit or next_bytes > byte_limit),
      do: {Enum.reverse(acc), count, bytes, entry.arrival_order},
      else: keep(rest, count_limit, byte_limit, [entry | acc], count + 1, next_bytes)
  end

  defp keep([], _count_limit, _byte_limit, acc, count, bytes),
    do: {Enum.reverse(acc), count, bytes, nil}
end
