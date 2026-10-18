# Private diagnostic fixture: samples only numeric transport state, never headers/keys.
defmodule TimeoutProbe do
  def atomize(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {String.to_atom(k), atomize(v)} end)

  def atomize(value) when is_list(value), do: Enum.map(value, &atomize/1)
  def atomize(value), do: value
  def now, do: System.monotonic_time(:millisecond)

  def sample(client, started) do
    s = :sys.get_state(client)

    %{
      at_ms: now() - started,
      connected: not is_nil(s.conn),
      connecting: not is_nil(s.connector),
      protocol: if(s.conn, do: Mint.HTTP.protocol(s.conn)),
      queue: :queue.len(s.queue),
      requests:
        Enum.map(s.requests, fn {_id, r} ->
          %{
            phase: r.phase,
            attempt: r.attempt,
            status: r.status,
            response_bytes: r.bytes,
            upload_remaining: if(is_binary(r.upload), do: byte_size(r.upload)),
            window:
              if(s.conn && r.ref && is_binary(r.upload),
                do: Mint.HTTP.request_body_window(s.conn, r.ref)
              )
          }
        end)
    }
  end

  def await(task, client, started, samples) do
    case Task.yield(task, 25) do
      nil -> await(task, client, started, [sample(client, started) | samples])
      {:ok, result} -> {result, Enum.reverse(samples)}
    end
  end

  def run do
    [input, output | args] = System.argv()
    if File.exists?(output), do: raise("Result path must be new")
    timeout = String.to_integer(Enum.at(args, 0, "2000"))

    protocols =
      case Enum.at(args, 1, "auto") do
        "http1" -> [:http1]
        "http2" -> [:http2]
        _ -> [:http1, :http2]
      end

    {:ok, client} =
      TypeSafe.Client.start_link(
        api_key: Application.fetch_env!(:order_desk, :typesafe_api_key),
        model: "jev-1.13.0",
        timeout: timeout,
        connect_timeout: 1000,
        max_concurrency: 4,
        max_queue: 8,
        retry: [max_attempts: 1],
        protocols: protocols
      )

    cold? = Enum.at(args, 2) == "cold"

    rows =
      input
      |> File.read!()
      |> Jason.decode!()
      |> Enum.map(fn row ->
        if cold?,
          do:
            :sys.replace_state(client, fn s ->
              if s.conn, do: Mint.HTTP.close(s.conn)
              %{s | conn: nil}
            end)

        state = atomize(row["input"])
        request = [state: state, questions: OrderDesk.Interpretation.questions(state)]
        {:ok, prepared} = TypeSafe.Request.prepare(request)
        bytes = prepared |> TypeSafe.Request.body("jev-1.13.0") |> IO.iodata_length()
        started = now()
        task = Task.async(fn -> TypeSafe.system_one(client, request) end)
        {result, samples} = await(task, client, started, [])

        record = %{
          id: row["id"],
          elapsed_ms: now() - started,
          body_bytes: bytes,
          result:
            case result do
              {:ok, r} ->
                %{
                  kind: "ok",
                  interpretation:
                    inspect(OrderDesk.Interpretation.interpret_answers(r.answers, state))
                }

              {:error, e} ->
                %{kind: e.kind, status: e.status}
            end,
          samples: samples
        }

        IO.puts(Jason.encode!(Map.drop(record, [:samples])))
        record
      end)

    GenServer.stop(client)

    File.write!(
      output,
      Jason.encode!(%{timeout: timeout, protocols: protocols, rows: rows}, pretty: true)
    )
  end
end

TimeoutProbe.run()
