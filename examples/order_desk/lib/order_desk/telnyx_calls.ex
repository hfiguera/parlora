defmodule OrderDesk.TelnyxCalls do
  @moduledoc "Bounded call-state transitions for the development Telnyx host."

  def new(config), do: %{config: config, calls: %{}, events: MapSet.new()}

  def admit(state, event) do
    with :ok <- validate_event(event),
         :ok <- capacity(state, event) do
      if MapSet.member?(state.events, event["id"]) do
        {:ok, state, []}
      else
        transition(state, event)
      end
    end
  end

  def close(state, call_id) do
    case state.calls[call_id] do
      %{terminal: false} = call ->
        {%{state | calls: Map.put(state.calls, call_id, %{call | terminal: true})},
         [{:hangup, call_id}]}

      _closed_or_missing ->
        {state, []}
    end
  end

  defp validate_event(%{"id" => id, "occurred_at" => time, "payload" => payload})
       when is_binary(id) and is_binary(time) and is_map(payload) do
    with {:ok, date, _offset} <- DateTime.from_iso8601(time),
         age <- DateTime.diff(DateTime.utc_now(), date),
         true <- age in -30..300,
         call when is_binary(call) and byte_size(call) in 1..512 <- payload["call_control_id"] do
      :ok
    else
      _invalid -> {:error, :invalid_event}
    end
  end

  defp validate_event(_event), do: {:error, :invalid_event}

  defp capacity(state, event) do
    known = Map.has_key?(state.calls, event["payload"]["call_control_id"])

    cond do
      MapSet.member?(state.events, event["id"]) -> :ok
      MapSet.size(state.events) >= 2_048 -> {:error, :backpressure}
      not known and map_size(state.calls) >= 64 -> {:error, :backpressure}
      true -> :ok
    end
  end

  defp transition(state, event) do
    payload = event["payload"]
    call_id = payload["call_control_id"]
    existing = state.calls[call_id]

    if authorized?(state.config, existing, payload) do
      call = existing || new_call(payload)
      update(state, event, call_id, call)
    else
      {:error, :call_not_allowed}
    end
  end

  defp authorized?(config, nil, payload) do
    payload["connection_id"] == config.connection_id and
      payload["to"] == config.phone_number and payload["direction"] in [nil, "incoming"] and
      is_binary(payload["call_session_id"])
  end

  defp authorized?(config, call, payload) do
    payload["connection_id"] in [nil, config.connection_id] and
      payload["call_session_id"] in [nil, call.call_session_id] and
      payload["to"] in [nil, config.phone_number]
  end

  defp new_call(payload) do
    %{
      call_session_id: payload["call_session_id"],
      initiated: false,
      answered: false,
      streaming: false,
      terminal: false,
      expires: System.monotonic_time(:millisecond) + 180_000
    }
  end

  defp update(state, event, id, %{terminal: true} = call),
    do: accepted(state, event, id, call, [])

  defp update(state, %{"event_type" => "call.hangup"} = event, id, call),
    do: accepted(state, event, id, %{call | terminal: true}, [{:close_stream, id}])

  defp update(state, %{"event_type" => type} = event, id, call)
       when type in ["streaming.stopped", "streaming.failed"] do
    accepted(state, event, id, %{call | terminal: true}, [{:close_stream, id}, {:hangup, id}])
  end

  defp update(state, %{"event_type" => "call.initiated", "payload" => payload} = event, id, call) do
    active =
      Enum.count(state.calls, fn {_id, record} -> record.initiated and not record.terminal end)

    cond do
      payload["direction"] != "incoming" ->
        {:error, :call_not_allowed}

      call.initiated ->
        accepted(state, event, id, call, [])

      active >= 4 ->
        {:error, :backpressure}

      call.answered ->
        accepted(state, event, id, %{call | initiated: true, streaming: true}, [
          {:streaming_start, id}
        ])

      true ->
        accepted(state, event, id, %{call | initiated: true}, [{:answer, id}])
    end
  end

  defp update(state, %{"event_type" => "call.answered"} = event, id, call) do
    if call.initiated and not call.streaming,
      do:
        accepted(state, event, id, %{call | answered: true, streaming: true}, [
          {:streaming_start, id}
        ]),
      else: accepted(state, event, id, %{call | answered: true}, [])
  end

  defp update(state, event, id, call), do: accepted(state, event, id, call, [])

  defp accepted(state, event, id, call, actions),
    do:
      {:ok,
       %{
         state
         | events: MapSet.put(state.events, event["id"]),
           calls: Map.put(state.calls, id, call)
       }, actions}
end
