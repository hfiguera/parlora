defmodule OrderDesk.TelnyxCallsTest do
  use ExUnit.Case, async: true
  alias OrderDesk.TelnyxCalls

  test "duplicates and reordered answered/initiated events never repeat a command" do
    state = new()
    initiated = event("call.initiated", "first")
    assert {:ok, state, [{:answer, "call"}]} = TelnyxCalls.admit(state, initiated)
    assert {:ok, state, []} = TelnyxCalls.admit(state, initiated)

    assert {:ok, state, [{:streaming_start, "call"}]} =
             TelnyxCalls.admit(state, event("call.answered", "second"))

    assert {:ok, _state, []} = TelnyxCalls.admit(state, event("call.answered", "third"))

    assert {:ok, reordered, []} = TelnyxCalls.admit(new(), event("call.answered", "answer-first"))
    assert {:ok, _state, [{:streaming_start, "call"}]} = TelnyxCalls.admit(reordered, initiated)
  end

  test "a hangup before initiation is retained and cannot resurrect a call" do
    assert {:ok, state, [{:close_stream, "call"}]} =
             TelnyxCalls.admit(new(), event("call.hangup", "first"))

    assert {:ok, state, []} = TelnyxCalls.admit(state, event("call.initiated", "second"))
    assert {:ok, state, []} = TelnyxCalls.admit(state, event("call.answered", "third"))
    assert state.calls["call"].terminal
  end

  test "stream termination requests call hangup separately and only once" do
    {:ok, state, _answer} = TelnyxCalls.admit(new(), event("call.initiated", "first"))

    stopped =
      event("streaming.stopped", "second") |> put_in(["payload"], %{"call_control_id" => "call"})

    assert {:ok, state, [{:close_stream, "call"}, {:hangup, "call"}]} =
             TelnyxCalls.admit(state, stopped)

    assert {:ok, state, []} = TelnyxCalls.admit(state, stopped)
    assert {^state, []} = TelnyxCalls.close(state, "call")
  end

  test "wrong connection, number, session and direction cannot control calls" do
    for {field, value} <- [
          {"connection_id", "other"},
          {"to", "+15555559999"},
          {"direction", "outgoing"}
        ] do
      bad = put_in(event("call.initiated", "first"), ["payload", field], value)
      assert {:error, :call_not_allowed} = TelnyxCalls.admit(new(), bad)
    end

    {:ok, state, _answer} = TelnyxCalls.admit(new(), event("call.initiated", "first"))

    wrong_session =
      put_in(event("call.answered", "second"), ["payload", "call_session_id"], "other")

    assert {:error, :call_not_allowed} = TelnyxCalls.admit(state, wrong_session)
  end

  test "old events and excess concurrent calls are rejected without growing state" do
    old = Map.put(event("call.initiated", "old"), "occurred_at", "2020-01-01T00:00:00Z")
    assert {:error, :invalid_event} = TelnyxCalls.admit(new(), old)

    state =
      Enum.reduce(1..4, new(), fn index, state ->
        request =
          put_in(
            event("call.initiated", "event-#{index}"),
            ["payload", "call_control_id"],
            "call-#{index}"
          )

        {:ok, next, [_command]} = TelnyxCalls.admit(state, request)
        next
      end)

    assert {:error, :backpressure} = TelnyxCalls.admit(state, event("call.initiated", "fifth"))
  end

  defp new, do: TelnyxCalls.new(%{connection_id: "connection", phone_number: "+15555550123"})

  defp event(type, id) do
    %{
      "id" => id,
      "event_type" => type,
      "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "payload" => %{
        "call_control_id" => "call",
        "call_session_id" => "session",
        "connection_id" => "connection",
        "direction" => "incoming",
        "to" => "+15555550123"
      }
    }
  end
end
