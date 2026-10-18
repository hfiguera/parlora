# Investigation only. Never persist credentials, audio, transcripts or raw process state.
defmodule ParloraGrokCorrectionTrace do
  use GenServer
  alias Parlora.Providers.Grok

  def start(path), do: GenServer.start(__MODULE__, path)

  def init(path) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, file} = File.open(path, [:write, :exclusive, :utf8])
    File.chmod!(path, 0o600)
    Code.ensure_loaded!(Grok)

    # Exclude audio deltas/appends from tracing; summaries contain lifecycle metadata only.
    :erlang.trace_pattern(
      {Grok, :event, 2},
      [
        {[:"$1", :"$2"],
         [
           {:"/=", {:map_get, "type", :"$1"}, "response.audio.delta"},
           {:"/=", {:map_get, "type", :"$1"}, "response.output_audio.delta"},
           {:"/=", {:map_get, "type", :"$1"}, "response.audio_transcript.delta"},
           {:"/=", {:map_get, "type", :"$1"}, "response.output_audio_transcript.delta"}
         ], []}
      ],
      [:local]
    )

    :erlang.trace_pattern(
      {Grok, :transmit, 2},
      [
        {[:"$1", :"$2"], [{:"/=", {:map_get, :type, :"$2"}, "input_audio_buffer.append"}], []}
      ],
      [:local]
    )

    :erlang.trace_pattern({Grok, :fail, 2}, [{:_, [], []}], [:local])
    :telemetry.attach({__MODULE__, self()}, [:parlora, :event], &__MODULE__.event/4, self())
    {:ok, %{file: file, count: 0}}
  end

  def event(_, _, %{source: :provider, type: :ready}, sink) do
    :erlang.trace(self(), true, [:call, :monotonic_timestamp, {:tracer, sink}])
    send(sink, {:ready, self()})
  end

  def event(_, _, %{source: :session, type: :ready}, sink),
    do: send(sink, {:session, self()})

  def event(_, _, _, _), do: :ok

  def handle_info({:session, pid}, s) do
    :ok = Parlora.subscribe(pid)
    {:noreply, s}
  end

  def handle_info({:parlora_event, event}, s) do
    if event.type in [
         :failed,
         :closed,
         :context_submitted,
         :context_rejected,
         :request_started,
         :request_completed,
         :result_delivery
       ], do: handle_info({:event, event}, s), else: {:noreply, s}
  end

  def handle_info({:ready, pid}, s),
    do: {:noreply, write(s, %{kind: :ready, provider: :erlang.phash2(pid)})}

  def handle_info({:event, event}, s) do
    error = Map.get(event.payload, :error)

    row = %{
      kind: :event,
      source: event.source,
      event: event.type,
      request: event.request_id,
      command: event.command_id,
      stage: Map.get(event.payload, :stage),
      reason: Map.get(event.payload, :reason),
      error_code: if(error, do: error.code),
      error_reason: if(error, do: error.details[:reason])
    }

    {:noreply, write(s, row)}
  end

  def handle_info({:trace_ts, pid, :call, {Grok, function, args}, time}, s) do
    {state, detail} =
      case {function, args} do
        {:event, [event, state]} ->
          response = event["response"] || %{}

          {state,
           %{
             type: event["type"],
             response_id: event["response_id"] || response["id"],
             status: response["status"],
             call_id: event["call_id"],
             item_id: event["item_id"],
             event_id: event["event_id"],
             error_code: get_in(event, ["error", "code"])
           }}

        {:transmit, [state, command]} ->
          item = command[:item] || %{}

          {state,
           %{
             type: command[:type],
             event_id: command[:event_id],
             item_type: item[:type],
             call_id: item[:call_id],
             output_status: output_status(item[:output])
           }}

        {:fail, [state, reason]} ->
          {state, %{reason: reason}}
      end

    snapshot = %{
      response: state.response,
      caller_speaking: state.caller_speaking,
      auto_response_pending: state.auto_response_pending,
      output_blocked: state.output_blocked,
      inbound_bytes: state.inbound.bytes,
      request_timer: state.request_timer != nil,
      want_response: MapSet.to_list(state.want_response),
      discarded: MapSet.to_list(state.discarded),
      calls:
        Map.new(state.calls.records, fn {id, call} -> {id, Map.take(call, [:status, :group])} end)
    }

    {:noreply,
     write(s, %{
       kind: function,
       provider: :erlang.phash2(pid),
       detail: detail,
       state: snapshot,
       monotonic_us: System.convert_time_unit(time, :native, :microsecond)
     })}
  end

  def handle_info(_, s), do: {:noreply, s}

  defp output_status(nil), do: nil

  defp output_status(output) do
    case Jason.decode(output) do
      {:ok, value} when is_map(value) -> value["status"]
      _ -> nil
    end
  end

  defp write(s, row) when s.count < 5_000 do
    IO.binwrite(
      s.file,
      Jason.encode!(Map.put(row, :at_ms, System.system_time(:millisecond))) <> "\n"
    )

    %{s | count: s.count + 1}
  end

  defp write(s, _), do: s
end
