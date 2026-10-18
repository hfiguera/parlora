# Test-only 0.1.0-client phase sampler. Never persist its raw process state.
defmodule ParloraInterpretationTrace do
  use GenServer
  def start_link(output), do: GenServer.start_link(__MODULE__, output)

  def init(output) do
    path = Path.join(output, "interpretation-phases.jsonl")
    {:ok, file} = File.open(path, [:write, :utf8])
    File.chmod!(path, 0o600)

    :telemetry.attach_many(
      {__MODULE__, self()},
      [[:typesafe, :request, :start], [:typesafe, :request, :stop]],
      &__MODULE__.event/4,
      self()
    )

    send(self(), :sample)
    {:ok, %{file: file, count: 0, previous: System.monotonic_time(:millisecond)}}
  end

  def event(name, measurements, metadata, pid),
    do: send(pid, {:event, List.last(name), measurements, metadata})

  def handle_info({:event, event, measurements, metadata}, state) do
    record = %{
      event: event,
      at_ms: System.system_time(:millisecond),
      request: :erlang.phash2(metadata.request_id),
      outcome: metadata[:outcome],
      measurements: Map.take(measurements, [:duration, :attempts])
    }

    {:noreply, write(state, record)}
  end

  def handle_info(:sample, state) do
    now = System.monotonic_time(:millisecond)

    record =
      try do
        case Process.whereis(OrderDesk.TypeSafe) do
          nil ->
            %{unavailable: true}

          pid ->
            s = :sys.get_state(pid, 500)

            %{
              connecting: not is_nil(s.connector),
              connected: not is_nil(s.conn),
              protocol: if(s.conn, do: Mint.HTTP.protocol(s.conn)),
              connection: if(s.conn, do: :erlang.phash2(Mint.HTTP.get_socket(s.conn))),
              queue: :queue.len(s.queue),
              mailbox: elem(Process.info(pid, :message_queue_len), 1),
              requests:
                Enum.map(s.requests, fn {id, r} ->
                  %{
                    id: :erlang.phash2(id),
                    phase: r.phase,
                    status: r.status,
                    response_bytes: r.bytes,
                    upload_remaining: if(is_binary(r.upload), do: byte_size(r.upload)),
                    window:
                      if(s.conn && r.ref && is_binary(r.upload),
                        do: Mint.HTTP.request_body_window(s.conn, r.ref)
                      ),
                    deadline_remaining_ms: r.deadline - now
                  }
                end)
            }
        end
      rescue
        _ -> %{sample_error: "unsupported_transport_state"}
      catch
        :exit, _ -> %{sample_timeout: true}
      end

    record =
      Map.merge(record, %{
        event: "sample",
        at_ms: System.system_time(:millisecond),
        sample_gap_ms: now - state.previous
      })

    if state.count < 40000, do: Process.send_after(self(), :sample, 50)
    {:noreply, write(%{state | previous: now}, record)}
  end

  def terminate(_reason, state) do
    try do
      :telemetry.detach({__MODULE__, self()})
    catch
      :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] -> :ok
    after
      File.close(state.file)
    end
  end

  defp write(%{count: n} = state, record) when n < 44000 do
    IO.write(state.file, Jason.encode!(record) <> "\n")
    %{state | count: n + 1}
  end

  defp write(state, _), do: state
end
