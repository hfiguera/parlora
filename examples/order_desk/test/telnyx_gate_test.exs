defmodule OrderDesk.TelnyxGateTest do
  use ExUnit.Case, async: false
  alias OrderDesk.TelnyxGate

  setup do
    owner = self()
    supervisor = start_supervised!(Task.Supervisor)

    executor = fn action, call, id, parameters, _options ->
      send(owner, {:command, self(), action, call, id, parameters})

      receive do
        {:result, result} -> result
      after
        5_000 -> {:error, :test_timeout}
      end
    end

    gate =
      start_supervised!(
        {TelnyxGate,
         config: %{
           api_key: "hidden-test-secret",
           public_url: "https://example.test",
           connection_id: "connection",
           phone_number: "+15555550123"
         },
         task_supervisor: supervisor,
         executor: executor}
      )

    %{gate: gate}
  end

  test "webhook admission stays responsive while a command runs and retries share one action" do
    event = event("call.initiated", "initial")
    assert :ok = TelnyxGate.event(event)

    assert_receive {:command, worker, :answer, "call", command_id,
                    %{"send_silence_when_idle" => true}}

    assert :ok = TelnyxGate.event(event)
    assert :ok = TelnyxGate.event(event("call.initiated", "retry"))
    refute_receive {:command, _pid, :answer, _call, _id, _params}, 20
    assert is_binary(command_id)
    assert TelnyxGate.observations().workers == 1
    refute inspect(TelnyxGate.observations()) =~ "hidden-test-secret"
    send(worker, {:result, {:ok, %{accepted?: true}}})
    assert :ok = TelnyxGate.event(event("call.answered", "answered"))
    assert_receive {:command, stream_worker, :streaming_start, "call", _id, parameters}
    assert parameters["stream_bidirectional_target_legs"] == "self"
    send(stream_worker, {:result, {:ok, %{accepted?: true}}})
  end

  test "media tokens are single-use, call-bound and hidden in observations" do
    {parameters, worker} = start_stream()
    token = parameters["stream_auth_token"]
    ticket = URI.parse(parameters["stream_url"]).path |> String.split("/") |> List.last()
    assert {:error, :invalid_ticket} = TelnyxGate.claim(ticket, "wrong")

    assert {:ok, [call_control_id: "call", call_session_id: "session"]} =
             TelnyxGate.claim(ticket, token)

    assert {:error, :invalid_ticket} = TelnyxGate.claim(ticket, token)
    assert {:error, :invalid_ticket} = TelnyxGate.claim("different-ticket", token)
    refute inspect(TelnyxGate.observations()) =~ token
    send(worker, {:result, {:ok, %{accepted?: true}}})
    assert :ok = TelnyxGate.event(event("call.hangup", "hungup"))
    assert_receive {:parlora_media_stream, :close}
    assert TelnyxGate.observations().unconfirmed_calls == 0
  end

  test "owner death closes the call and a late result never restarts it" do
    {parameters, stream_worker} = start_stream()
    parent = self()

    socket =
      spawn(fn ->
        ticket =
          parameters["stream_url"]
          |> URI.parse()
          |> Map.fetch!(:path)
          |> String.split("/")
          |> List.last()

        send(parent, {:claimed, TelnyxGate.claim(ticket, parameters["stream_auth_token"])})

        receive do
          :disconnect -> :ok
        end
      end)

    assert_receive {:claimed, {:ok, _identity}}
    send(socket, :disconnect)
    assert_receive {:command, hangup_worker, :hangup, "call", _id, %{}}
    send(stream_worker, {:result, {:ok, %{accepted?: true}}})
    assert :ok = TelnyxGate.event(event("call.answered", "late-answer"))
    refute_receive {:command, _pid, :streaming_start, _call, _id, _params}, 20
    assert TelnyxGate.observations().calls["call"].terminal
    send(hangup_worker, {:result, {:error, :uncertain}})
    assert TelnyxGate.observations().unconfirmed_calls == 1
  end

  test "expired credentials fail closed, and sweep requests hangup", %{gate: gate} do
    {parameters, worker} = start_stream()

    ticket =
      parameters["stream_url"]
      |> URI.parse()
      |> Map.fetch!(:path)
      |> String.split("/")
      |> List.last()

    :sys.replace_state(gate, fn state ->
      put_in(state, [:tickets, "call", :expires], System.monotonic_time(:millisecond) - 1)
    end)

    assert {:error, :invalid_ticket} = TelnyxGate.claim(ticket, parameters["stream_auth_token"])
    send(gate, :sweep)
    assert_receive {:command, hangup, :hangup, "call", _id, _params}
    send(worker, {:result, {:ok, %{}}})
    send(hangup, {:result, {:ok, %{}}})
  end

  test "drain refuses new calls and hangup is independent of media termination" do
    assert :ok = TelnyxGate.event(event("call.initiated", "initial"))
    assert_receive {:command, answer, :answer, "call", _id, _params}
    assert :ok = TelnyxGate.drain()
    assert_receive {:command, hangup, :hangup, "call", _id, _params}
    next = put_in(event("call.initiated", "new"), ["payload", "call_control_id"], "another")
    assert {:error, :backpressure} = TelnyxGate.event(next)
    send(answer, {:result, {:ok, %{}}})
    send(hangup, {:result, {:ok, %{}}})
  end

  test "concurrent calls cannot exchange tickets and ending one leaves the other admitted" do
    streams =
      for call <- ["alpha", "beta"] do
        initiated =
          put_in(event("call.initiated", call <> "-init"), ["payload", "call_control_id"], call)

        answered =
          put_in(event("call.answered", call <> "-answer"), ["payload", "call_control_id"], call)

        assert :ok = TelnyxGate.event(initiated)
        assert_receive {:command, answer, :answer, ^call, _id, _params}
        send(answer, {:result, {:ok, %{}}})
        assert :ok = TelnyxGate.event(answered)
        assert_receive {:command, stream, :streaming_start, ^call, _id, params}
        send(stream, {:result, {:ok, %{}}})

        {params["stream_url"]
         |> URI.parse()
         |> Map.fetch!(:path)
         |> String.split("/")
         |> List.last(), params["stream_auth_token"]}
      end

    [{first_ticket, first_token}, {second_ticket, second_token}] = streams
    assert {:error, :invalid_ticket} = TelnyxGate.claim(first_ticket, second_token)
    assert {:error, :invalid_ticket} = TelnyxGate.claim(second_ticket, first_token)
    assert {:ok, first} = TelnyxGate.claim(first_ticket, first_token)
    assert first[:call_control_id] == "alpha"
    assert {:ok, second} = TelnyxGate.claim(second_ticket, second_token)
    assert second[:call_control_id] == "beta"

    ended = put_in(event("call.hangup", "alpha-end"), ["payload", "call_control_id"], "alpha")
    assert :ok = TelnyxGate.event(ended)
    assert_receive {:parlora_media_stream, :close}
    refute_receive {:parlora_media_stream, :close}, 20
    state = TelnyxGate.observations()
    assert state.calls["alpha"].terminal
    refute state.calls["beta"].terminal
    assert state.unconfirmed_calls == 1
  end

  for order <- [:webhook_first, :response_first] do
    test "hangup rejection is reconciled when #{order}" do
      {_parameters, stream} = start_stream()
      send(stream, {:result, {:ok, %{accepted?: true}}})
      assert :ok = TelnyxGate.event(event("streaming.stopped", "stopped"))
      assert_receive {:command, hangup, :hangup, "call", _id, %{}}

      failure =
        {:error, Parlora.Error.new(:adapter_failed, "rejected", %{http_status: 422, attempts: 1})}

      if unquote(order) == :webhook_first do
        assert :ok = TelnyxGate.event(event("call.hangup", "ended"))
        send(hangup, {:result, failure})
      else
        send(hangup, {:result, failure})
        await_observation(:unknown)
        assert TelnyxGate.observations().unconfirmed_calls == 1
        assert :ok = TelnyxGate.event(event("call.hangup", "ended"))
      end

      await_observation(:reconciled)
      observations = TelnyxGate.observations()
      assert observations.unconfirmed_calls == 0
      assert observations.calls["call"].terminal
      assert Enum.any?(observations.commands, &match?(%{outcome: %{status: :unknown}}, &1))
      assert :ok = TelnyxGate.event(event("call.hangup", "ended-again"))
      assert :ok = TelnyxGate.event(event("streaming.stopped", "stopped-again"))
      refute_receive {:command, _pid, :hangup, _call, _id, _params}, 20

      assert Enum.count(TelnyxGate.observations().commands, fn entry ->
               match?(%{status: :reconciled, resolution: :call_ended}, entry.outcome)
             end) == 1
    end
  end

  test "specific already-ended evidence releases the slot even without a hangup webhook" do
    {_parameters, stream} = start_stream()
    send(stream, {:result, {:ok, %{accepted?: true}}})
    assert :ok = TelnyxGate.event(event("streaming.failed", "failed"))
    assert_receive {:command, hangup, :hangup, "call", _id, %{}}

    failure =
      Parlora.Error.new(:adapter_failed, "not accepted", %{
        http_status: 422,
        telnyx_codes: ["90018"],
        remote_call_state: :ended,
        outcome: :unknown
      })

    send(hangup, {:result, {:error, failure}})
    await_observation(:reconciled)
    observations = TelnyxGate.observations()
    assert observations.unconfirmed_calls == 0

    assert Enum.any?(observations.commands, fn entry ->
             match?(%{status: :reconciled, evidence: :api_response}, entry.outcome)
           end)

    assert Enum.any?(observations.commands, fn entry ->
             match?(%{error: %{telnyx_codes: ["90018"]}}, entry.outcome)
           end)

    assert :ok = TelnyxGate.event(event("call.answered", "late"))
    refute_receive {:command, _pid, :streaming_start, _call, _id, _params}, 20
  end

  test "generic rejection after a media failure retains the unresolved call slot" do
    {_parameters, stream} = start_stream()
    send(stream, {:result, {:ok, %{accepted?: true}}})
    assert :ok = TelnyxGate.event(event("streaming.failed", "failed"))
    assert_receive {:command, hangup, :hangup, "call", _id, %{}}

    error =
      Parlora.Error.new(:adapter_failed, "rejected", %{http_status: 422, telnyx_codes: ["90015"]})

    send(hangup, {:result, {:error, error}})
    await_observation(:unknown)
    assert TelnyxGate.observations().unconfirmed_calls == 1

    refute Enum.any?(TelnyxGate.observations().commands, fn entry ->
             match?(%{status: :reconciled}, entry.outcome)
           end)
  end

  defp await_observation(status, attempts \\ 100) do
    found =
      Enum.any?(TelnyxGate.observations().commands, fn entry ->
        match?(%{action: :hangup, status: ^status}, entry.outcome)
      end)

    if found or attempts == 0 do
      assert found
    else
      Process.sleep(5)
      await_observation(status, attempts - 1)
    end
  end

  defp start_stream do
    :ok = TelnyxGate.event(event("call.initiated", "initial"))
    assert_receive {:command, answer, :answer, "call", _id, _parameters}
    send(answer, {:result, {:ok, %{}}})
    :ok = TelnyxGate.event(event("call.answered", "answered"))
    assert_receive {:command, worker, :streaming_start, "call", _id, parameters}
    {parameters, worker}
  end

  defp event(type, id),
    do: %{
      "id" => id,
      "event_type" => type,
      "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "payload" => %{
        "call_control_id" => "call",
        "call_session_id" => "session",
        "connection_id" => "connection",
        "to" => "+15555550123",
        "direction" => "incoming"
      }
    }
end
