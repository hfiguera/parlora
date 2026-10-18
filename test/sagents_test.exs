defmodule Parlora.SagentsTest do
  use ExUnit.Case, async: true
  alias Parlora.{AdapterInit, BackendRequest, Event, Limits}
  alias Parlora.Backends.Sagents, as: Backend
  alias Parlora.TestSupport.SagentsModel

  test "real framework completion is structured, isolated and idempotent" do
    pid = backend()
    assert_receive {:parlora_event, %Event{type: :ready, payload: %{capabilities: caps}}}
    assert caps.cancellation == :advisory
    refute caps.updates? or caps.progress? or caps.clarification?
    slow = request("slow", %{order: "123", gate: true})
    fast = %{request("fast", %{order: "124"}) | task_revision: 2}
    assert :ok = Backend.submit(pid, slow)
    assert_receive {:lookup_waiting, "123", worker}
    assert :ok = Backend.submit(pid, fast)
    assert :ok = Backend.submit(pid, fast)
    assert_receive {:model_call, "fast", 0, _}

    assert {:error, %{code: :invalid_argument}} =
             Backend.submit(pid, %{fast | input: %{order: "999"}})

    assert_receive {:parlora_event,
                    %Event{
                      type: :request_completed,
                      request_id: "fast",
                      payload: %{
                        task_id: "task",
                        task_revision: 2,
                        provider_generation: 7,
                        facts: %{order: "124"}
                      }
                    }},
                   1_000

    send(worker, :finish)
    assert_receive {:parlora_event, %Event{type: :request_completed, request_id: "slow"}}
    assert :ok = Backend.submit(pid, fast)
    refute_receive {:model_call, "fast", _, _}, 20
    assert {:error, %{code: :unsupported}} = Backend.update(pid, "update", "fast", fast)
    assert :ok = Backend.close(pid, "close", :finish)
    assert :ok = Backend.close(pid, "close", :finish)
    assert_receive {:parlora_event, %Event{type: :closed}}
    refute_receive {:parlora_event, %Event{type: :closed}}, 20
  end

  test "rejected duplicate admission stays rejected after capacity becomes free" do
    pid = backend(:complete, %Limits{max_jobs: 1})
    assert :ok = Backend.submit(pid, request("active", %{order: "123", gate: true}))
    assert_receive {:lookup_waiting, "123", worker}
    rejected = request("rejected", %{order: "124"})
    assert {:error, %{code: :backpressure}} = Backend.submit(pid, rejected)
    send(worker, :finish)
    assert_receive {:parlora_event, %Event{type: :request_completed}}
    assert {:error, %{code: :backpressure}} = Backend.submit(pid, rejected)
  end

  test "multi-step tools run through Sagents before terminal mapping" do
    pid = backend(:multi_step)
    assert :ok = Backend.submit(pid, request("multi", %{order: "123"}))
    assert_receive {:read_tool, "multi"}
    assert_receive {:model_call, "multi", 1, _}
    assert_receive {:parlora_event, %Event{type: :request_completed}}, 1_000
  end

  for mode <- [:model_error, :tool_error, :no_tool] do
    @mode mode
    test "#{mode} cannot turn model content into authoritative completion" do
      pid = backend(@mode)
      assert :ok = Backend.submit(pid, request("failure", %{order: "123"}))
      assert_receive {:parlora_event, %Event{type: :request_uncertain, payload: payload}}, 1_000
      refute inspect(payload) =~ "private-key-and-prompt"
      refute_receive {:parlora_event, %Event{type: :request_completed}}, 20
      assert :sys.get_state(pid).jobs == %{}
    end
  end

  for reason <- [:cancel, :crash, :close] do
    @reason reason
    test "#{reason} stops local work without confirming an external cancellation" do
      pid = backend(:complete, %Limits{shutdown_timeout_ms: 100})
      assert :ok = Backend.submit(pid, request("stopped", %{order: "123", gate: true}))
      assert_receive {:lookup_waiting, "123", worker}
      monitor = Process.monitor(worker)

      expected_reason =
        case @reason do
          :cancel ->
            assert :ok = Backend.cancel(pid, "cancel", "stopped", :caller)
            assert :ok = Backend.cancel(pid, "cancel", "stopped", :caller)

            assert_receive {:parlora_event,
                            %Event{type: :cancellation_requested, command_id: "cancel"}}

            :cancellation_requested

          :crash ->
            Process.exit(worker, :kill)
            :observer_exited

          :close ->
            assert :ok = Backend.close(pid, "close", :finish)
            :shutdown_deadline
        end

      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000

      assert_receive {:parlora_event,
                      %Event{
                        type: :request_uncertain,
                        request_id: "stopped",
                        payload: %{reason: ^expected_reason}
                      }},
                     1_000

      refute_receive {:parlora_event, %Event{type: :request_cancelled}}, 20
      assert :sys.get_state(pid).jobs == %{}
      if @reason == :close, do: assert_receive({:parlora_event, %Event{type: :closed}})
    end
  end

  test "deadline stops local work without confirming an external cancellation" do
    pid = backend(:complete, %Limits{job_timeout_ms: 100})
    assert :ok = Backend.submit(pid, request("stopped", %{order: "123", gate: true}))

    # The real deadline covers startup too; reaching the tool is not a prerequisite.
    assert_receive {:parlora_event,
                    %Event{
                      type: :request_uncertain,
                      request_id: "stopped",
                      payload: %{reason: :execution_deadline}
                    }},
                   1_000

    refute_receive {:parlora_event, %Event{type: :request_cancelled}}, 20
    refute_receive {:parlora_event, %Event{type: :request_completed}}, 20
    state = :sys.get_state(pid)
    assert state.jobs == %{}
    assert Task.Supervisor.children(state.workers) == []
  end

  test "owner shutdown also stops the execution supervisor and blocked tool" do
    observer = self()

    owner =
      spawn(fn ->
        {:ok, pid} = Backend.start_link(init(observer, %Limits{}), SagentsModel.options(observer))
        send(observer, {:owned, pid, :sys.get_state(pid).workers})
        Backend.submit(pid, request("owned", %{order: "123", gate: true}))

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:owned, pid, supervisor}
    assert_receive {:lookup_waiting, "123", worker}
    refs = Enum.map([pid, supervisor, worker], &Process.monitor/1)
    Process.exit(owner, :kill)
    Enum.each(refs, fn ref -> assert_receive {:DOWN, ^ref, :process, _, _}, 1_000 end)
  end

  test "expired requests do not start and status does not expose private state" do
    pid = backend()

    expired = %{
      request("expired", %{order: "123"})
      | deadline_at_us: System.monotonic_time(:microsecond) - 1_000
    }

    assert {:error, %{code: :timeout}} = Backend.submit(pid, expired)
    refute_receive {:model_call, "expired", _, _}, 20
    assert :ok = Backend.submit(pid, request("private", %{order: "private-order", gate: true}))
    assert_receive {:lookup_waiting, "private-order", _}
    refute inspect(:sys.get_status(pid)) =~ "private-order"
    assert :ok = Backend.close(pid, "cancel-close", :cancel)
    assert_receive {:parlora_event, %Event{type: :request_uncertain}}
    assert_receive {:parlora_event, %Event{type: :closed}}
    assert {:error, %{code: :closed}} = Backend.submit(pid, request("after", %{order: "124"}))
  end

  test "a mapped cancellation cannot claim that stopping local work cancelled an external action" do
    pid = backend(:complete, %Limits{}, result: fn _ -> %{status: :cancelled, facts: %{}} end)
    assert :ok = Backend.submit(pid, request("invalid-cancellation", %{order: "123"}))

    assert_receive {:parlora_event,
                    %Event{type: :request_uncertain, payload: %{reason: :invalid_result}}}

    refute_received {:parlora_event, %Event{type: :request_cancelled}}
  end

  defp backend(mode \\ :complete, limits \\ %Limits{}, extra \\ []) do
    start_supervised!(%{
      id: {Backend, make_ref()},
      start:
        {Backend, :start_link,
         [init(self(), limits), Keyword.merge(SagentsModel.options(self(), mode), extra)]},
      restart: :temporary
    })
  end

  defp init(observer, limits),
    do: %AdapterInit{
      session_id: "session",
      adapter_id: "backend",
      generation: 0,
      event_sink: observer,
      limits: limits
    }

  defp request(id, input),
    do: %BackendRequest{
      id: id,
      task_id: "task",
      task_revision: 1,
      provider_generation: 7,
      input: input
    }
end
