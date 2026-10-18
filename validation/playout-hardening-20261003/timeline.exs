defmodule Parlora.Validation.PlayoutTimeline do
  @moduledoc false
  @limit 131_072

  def open(nil, _init), do: nil

  def open(directory, init) do
    table = :ets.new(:playout_timeline, [:ordered_set, :public])
    :ets.insert(table, {:count, 0})
    handler = make_ref()

    :ok =
      :telemetry.attach_many(
        handler,
        [[:parlora, :audio, :playout], [:parlora, :audio, :tick]],
        &__MODULE__.record/4,
        {init.session_id, table}
      )

    %{table: table, handler: handler, path: Path.join(directory, init.session_id <> ".json")}
  end

  def record(event, measurements, metadata, {session, table}) do
    if metadata.session_id == session,
      do:
        insert(table, %{
          kind: List.last(event),
          measurements: measurements,
          direction: Map.get(metadata, :direction)
        })
  end

  def mark(nil, _kind), do: :ok

  def mark(trace, kind),
    do:
      insert(trace.table, %{
        kind: kind,
        measurements: %{at_us: System.monotonic_time(:microsecond)}
      })

  defp insert(table, row) do
    n = :ets.update_counter(table, :count, 1)
    if n <= @limit, do: :ets.insert(table, {n, row})
  end

  def close(nil), do: :ok

  def close(trace) do
    :telemetry.detach(trace.handler)
    count = :ets.lookup_element(trace.table, :count, 2)
    rows = for {key, row} <- :ets.tab2list(trace.table), is_integer(key), do: row

    File.write!(
      trace.path,
      Jason.encode!(%{rows: rows, seen: count, limit: @limit, truncated: count > @limit}) <> "\n"
    )

    :ets.delete(trace.table)
    :ok
  end
end
