defmodule Parlora.Providers.Prism.Calls do
  @moduledoc false
  alias Parlora.{CommandLog, Error}
  alias Parlora.Providers.Prism.Protocol

  def new(limit),
    do: %{log: %CommandLog{limit: limit}, records: %{}, round: nil, timeout_retried: MapSet.new()}

  def begin(calls, response_id, first_sequence, recover_association?, reply_results) do
    round = %{
      id: response_id,
      first_sequence: first_sequence,
      first_stream_id: nil,
      done?: false,
      speak?: false,
      waiting: MapSet.new(),
      results: [],
      reply_results: reply_results,
      reply_read?: false,
      association: if(recover_association?, do: :available)
    }

    %{calls | round: round}
  end

  def generated_audio(%{round: %{first_stream_id: nil} = round} = calls, stream_id),
    do: %{calls | round: %{round | first_stream_id: stream_id, association: nil}}

  def generated_audio(calls, _stream_id), do: calls

  # An older reply can still have audio at the front of the output queue.
  def read_audio(
        %{round: %{first_sequence: first, reply_results: [_ | _], reply_read?: false}} = calls,
        sequence
      )
      when sequence >= first,
      do: put_in(calls.round.reply_read?, true)

  def read_audio(calls, _sequence), do: calls

  def recover_association?(%{round: %{association: :available}} = calls, id),
    do: in_round?(calls, id)

  def recover_association?(_calls, _id), do: false

  def supersede(calls), do: %{calls | round: nil}

  def unspoken_results(%{round: %{reply_read?: true, results: results}}),
    do: Enum.reverse(results)

  def unspoken_results(%{round: %{reply_results: pending, results: results}}),
    do: pending ++ Enum.reverse(results)

  def unspoken_results(_calls), do: []

  def interrupted_reply(%{round: %{reply_read?: true, reply_results: [_ | _]} = round}),
    do: {round.first_sequence, round.first_stream_id, round.reply_results}

  def interrupted_reply(_calls), do: nil

  def retry_timed_out(calls) do
    results =
      Enum.reject(unspoken_results(calls), fn {id, _update} -> id in calls.timeout_retried end)

    retried =
      Enum.reduce(results, calls.timeout_retried, fn {id, _update}, seen ->
        MapSet.put(seen, id)
      end)

    {results, %{calls | timeout_retried: retried}}
  end

  def finish(%{round: %{id: id} = round} = calls, id, "completed"),
    do: %{calls | round: %{round | done?: true}}

  def finish(%{round: %{id: id}} = calls, id, _status), do: supersede(calls)
  def finish(calls, _id, _status), do: calls

  def admit(calls, %{"call_id" => id, "response_id" => parent} = event)
      when is_binary(id) and byte_size(id) in 1..512 and is_binary(parent) do
    with {:ok, args} <- Protocol.arguments(event),
         {:new, log} <- CommandLog.admit(calls.log, id, {parent, args}) do
      calls = %{calls | log: log, records: Map.put(calls.records, id, :pending)}

      case calls.round do
        %{id: ^parent} = round ->
          {:new, args, %{calls | round: %{round | waiting: MapSet.put(round.waiting, id)}}}

        _stale ->
          {:stale, id, calls}
      end
    end
  end

  def admit(_calls, _event), do: Error.tuple(:invalid_argument, "Malformed Prism tool call")

  def status(calls, id), do: calls.records[id]

  def in_round?(%{round: %{waiting: waiting}}, id), do: MapSet.member?(waiting, id)
  def in_round?(_calls, _id), do: false

  def submit(calls, id, speech) do
    calls = put_in(calls.records[id], :submitted)

    if in_round?(calls, id) do
      case speech do
        true -> put_in(calls.round.speak?, true)
        :association -> put_in(calls.round.association, :scheduled)
        false -> calls
      end
    else
      calls
    end
  end

  def acknowledge(calls, id, update \\ nil) do
    calls = put_in(calls.records[id], :acknowledged)

    case calls.round do
      nil ->
        calls

      round ->
        results = if update, do: [{id, update} | round.results], else: round.results
        %{calls | round: %{round | waiting: MapSet.delete(round.waiting, id), results: results}}
    end
  end

  def reject(calls, id) do
    calls = put_in(calls.records[id], :rejected)

    case calls.round do
      %{waiting: waiting} -> if MapSet.member?(waiting, id), do: supersede(calls), else: calls
      nil -> calls
    end
  end

  def continuation(%{round: %{done?: true, waiting: waiting} = round} = calls) do
    cond do
      MapSet.size(waiting) != 0 ->
        nil

      round.speak? ->
        {round.id, :continue, unspoken_results(calls), supersede(calls)}

      round.association == :scheduled ->
        {round.id, :association_retry, round.reply_results, supersede(calls)}

      true ->
        nil
    end
  end

  def continuation(_calls), do: nil
end
