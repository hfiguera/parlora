# Numeric-only diagnostics for the bounded macOS live stability harness.
# Run with MIX_ENV=test and an unused output filename as the only argument.
defmodule Parlora.OutputTrace do
  @moduledoc false
  @event_limit 120_000

  def run(path) do
    # Open exclusively before starting paid work; never overwrite an existing trace.
    File.open!(path, [:write, :exclusive], fn file ->
      table = :ets.new(:output_trace, [:ordered_set, :public, write_concurrency: true])
      :ets.insert(table, {:count, 0})
      origin = System.monotonic_time(:microsecond)

      :ok =
        :telemetry.attach_many(
          "parlora-output-trace",
          [
            [:parlora, :provider, :audio_read],
            [:parlora, :provider, :audio_received],
            [:parlora, :audio, :tick]
          ],
          &__MODULE__.handle/4,
          {table, origin}
        )

      try do
        Code.require_file("stability_live.exs", __DIR__)
      after
        :telemetry.detach("parlora-output-trace")
        write_trace(table, file)
        :ets.delete(table)
      end
    end)
  end

  def handle(event, measurements, metadata, {table, origin}) do
    if metadata[:direction] != :input do
      index = :ets.update_counter(table, :count, 1)

      if index <= @event_limit do
        :ets.insert(table, {
          index,
          %{
            elapsed_us: System.monotonic_time(:microsecond) - origin,
            event: List.last(event),
            measurements: measurements
          }
        })
      end
    end
  end

  defp write_trace(table, file) do
    count = :ets.lookup_element(table, :count, 2)

    :ets.foldl(
      fn
        {:count, _count}, acc ->
          acc

        {_index, row}, acc ->
          IO.puts(file, Jason.encode!(row))
          acc
      end,
      :ok,
      table
    )

    IO.puts(file, Jason.encode!(%{events_seen: count, truncated: count > @event_limit}))
  end
end

case System.argv() do
  [path] -> Parlora.OutputTrace.run(path)
  _other -> raise "Usage: mix run scripts/trace_output.exs /path/to/unused-trace.jsonl"
end
