defmodule Parlora.LegionTest do
  use ExUnit.Case, async: true
  alias Parlora.{AdapterInit, BackendRequest, Event, Limits}
  alias Parlora.Backends.Legion, as: Backend
  alias Parlora.TestSupport.LegionModel

  test "real Legion and Lua use native results, preserve identity and deduplicate admission" do
    pid = backend()
    assert_receive {:parlora_event, %Event{type: :ready, payload: %{capabilities: caps}}}
    assert caps.cancellation == :advisory
    refute caps.updates? or caps.progress? or caps.clarification?
    request = request("first", %{order: "123"})
    assert :ok = Backend.submit(pid, request)
    assert :ok = Backend.submit(pid, request)
    assert_receive {:parlora_event, %Event{type: :request_completed, payload: result}}, 5_000
    assert result.facts == %{order: "123"}
    assert result.request_id == "first" and result.task_id == "task"
    assert result.task_revision == 2 and result.provider_generation == 7
    assert_receive {:legion_wire, "first", wire}
    assert wire["model"] == "gpt-6-luna"
    assert wire["reasoning"]["effort"] == "none"
    refute inspect(wire) =~ "private-key-and-prompt"
    assert_receive {:native_operation, "first", _}
    refute_receive {:native_operation, "first", _}, 20
    assert :ok = Backend.submit(pid, request)

    assert {:error, %{code: :invalid_argument}} =
             Backend.submit(pid, %{request | input: %{order: "999"}})

    assert {:error, %{code: :unsupported}} = Backend.update(pid, "u", request.id, request)
    assert :ok = Backend.close(pid, "close", :finish)
    assert :ok = Backend.close(pid, "close", :finish)
    assert_receive {:parlora_event, %Event{type: :closed}}
    refute_receive {:parlora_event, %Event{type: :closed}}, 20
  end

  test "Lua mutations do not alter native facts, and native failures retain their status" do
    for {mode, expected} <- [
          {:mutated_native, :request_completed},
          {:native_failed, :request_failed},
          {:help, :request_completed}
        ] do
      pid = backend(mode)
      assert :ok = Backend.submit(pid, request("native", %{order: "123"}))
      assert_receive {:parlora_event, %Event{type: ^expected, payload: result}}, 5_000
      assert result.facts == %{order: "123"}
      assert result.task_revision == 2 and result.provider_generation == 7
    end
  end

  test "concurrent requests never share native results and capacity rejection is stable" do
    pid = backend(:complete, %Limits{max_jobs: 2})
    assert :ok = Backend.submit(pid, request("a", %{order: "123", gate: true}))
    assert_receive {:lookup_waiting, "123", first}, 5_000
    assert :ok = Backend.submit(pid, request("b", %{order: "124", gate: true}))
    assert_receive {:lookup_waiting, "124", second}
    rejected = request("reject", %{order: "825"})
    assert {:error, %{code: :backpressure}} = Backend.submit(pid, rejected)
    send(second, :finish)

    assert_receive {:parlora_event,
                    %Event{
                      type: :request_completed,
                      request_id: "b",
                      payload: %{facts: %{order: "124"}}
                    }}

    assert {:error, %{code: :backpressure}} = Backend.submit(pid, rejected)
    send(first, :finish)

    assert_receive {:parlora_event,
                    %Event{
                      type: :request_completed,
                      request_id: "a",
                      payload: %{facts: %{order: "123"}}
                    }}
  end

  test "repeated Lua calls consume budget but reuse native operations" do
    pid = backend(:repeat)
    assert :ok = Backend.submit(pid, request("repeat", %{order: "123"}))
    assert_receive {:parlora_event, %Event{type: :request_completed}}, 5_000
    assert_receive {:native_operation, "repeat", _}
    refute_receive {:native_operation, "repeat", _}, 20
    limited = backend(:repeat, %Limits{}, max_tool_calls: 3)
    assert :ok = Backend.submit(limited, request("limited", %{order: "123"}))
    assert_receive {:parlora_event, %Event{type: :request_uncertain, request_id: "limited"}}
  end

  for mode <- [
        :fake,
        :native_without_complete,
        :unauthorized,
        :tool_metadata,
        :model_error,
        :tool_error,
        :cpu,
        :heap
      ] do
    @mode mode
    test "#{mode} cannot provide an authoritative completion" do
      pid = backend(@mode, %Limits{}, sandbox_timeout: 100, sandbox_max_reductions: 100_000)
      assert :ok = Backend.submit(pid, request("bad", %{order: "123"}))
      assert_receive {:parlora_event, %Event{type: :request_uncertain, payload: payload}}, 5_000
      refute inspect(payload) =~ "private-key-and-prompt"
      assert payload.task_id == "task" and payload.task_revision == 2
      assert payload.provider_generation == 7
      refute_receive {:parlora_event, %Event{type: :request_completed}}, 20
      assert :sys.get_state(pid).jobs == %{}
    end
  end

  for mode <- [:cancel, :deadline, :worker_crash, :close_finish, :close_cancel] do
    @mode mode
    @expect_closed mode in [:close_finish, :close_cancel]
    test "#{mode} stops agent, collector and sandbox without claiming cancelled effects" do
      pid = backend(:complete, %Limits{job_timeout_ms: 4_000, shutdown_timeout_ms: 200})
      assert :ok = Backend.submit(pid, request("stop", %{order: "123", gate: true}))
      assert_receive {:legion_model_call, "stop", _, agent}, 5_000
      assert_receive {:lookup_waiting, "123", collector}
      assert :proc_lib.translate_initial_call(agent) == {Legion.AgentServer, :init, 1}
      {:monitored_by, monitors} = Process.info(collector, :monitored_by)
      sandbox = Enum.find(monitors, &(&1 != self()))
      assert is_pid(sandbox)
      {:monitored_by, sandbox_monitors} = Process.info(sandbox, :monitored_by)
      watchdogs = sandbox_monitors -- [agent, self()]
      assert watchdogs != []
      refs = Enum.map([agent, collector, sandbox | watchdogs], &Process.monitor/1)

      case @mode do
        :cancel ->
          assert :ok = Backend.cancel(pid, "cancel", "stop", :caller)
          assert :ok = Backend.cancel(pid, "cancel", "stop", :caller)

        :worker_crash ->
          Process.exit(:sys.get_state(pid).jobs["stop"].task.pid, :kill)

        :close_finish ->
          assert :ok = Backend.close(pid, "close", :finish)

        :close_cancel ->
          assert :ok = Backend.close(pid, "close", :cancel)

        :deadline ->
          :ok
      end

      assert_receive {:parlora_event, %Event{type: :request_uncertain}}, 5_000
      Enum.each(refs, fn ref -> assert_receive {:DOWN, ^ref, :process, _, _}, 2_000 end)
      refute_receive {:parlora_event, %Event{type: :request_cancelled}}, 20
      assert :sys.get_state(pid).jobs == %{}

      if @expect_closed,
        do: assert_receive({:parlora_event, %Event{type: :closed}})
    end
  end

  test "expired requests and invalid limits never execute; backend status is redacted" do
    pid = backend()

    expired = %{
      request("expired", %{order: "123"})
      | deadline_at_us: System.monotonic_time(:microsecond) - 1_000
    }

    assert {:error, %{code: :timeout}} = Backend.submit(pid, expired)

    for key <- [
          :max_iterations,
          :max_retries,
          :max_tool_calls,
          :sandbox_timeout,
          :sandbox_max_heap,
          :sandbox_max_reductions
        ] do
      assert {:error, %{code: :invalid_argument}} =
               Backend.start_link(
                 init(%Limits{}),
                 Keyword.put(LegionModel.options(self()), key, :infinity)
               )
    end

    for key <- [:max_jobs, :max_records, :job_timeout_ms, :shutdown_timeout_ms] do
      assert {:error, %{code: :invalid_argument}} =
               Backend.start_link(
                 init(Map.put(%Limits{}, key, :infinity)),
                 LegionModel.options(self())
               )
    end

    refute inspect(:sys.get_status(pid)) =~ "private-key-and-prompt"
  end

  test "sandbox time budget stops a blocked native call before the outer job deadline" do
    pid = backend(:complete, %Limits{job_timeout_ms: 10_000}, sandbox_timeout: 100)
    assert :ok = Backend.submit(pid, request("sandbox-time", %{order: "123", gate: true}))
    assert_receive {:lookup_waiting, "123", collector}, 5_000
    ref = Process.monitor(collector)

    assert_receive {:parlora_event,
                    %Event{type: :request_uncertain, payload: %{reason: :framework_failure}}},
                   2_000

    assert_receive {:DOWN, ^ref, :process, ^collector, _}, 1_000
  end

  test "iteration and retry limits bound actual model calls" do
    for {mode, options, expected} <- [
          {:continue, [max_iterations: 2], 2},
          {:invalid_code, [max_retries: 1], 2}
        ] do
      id = Atom.to_string(mode)
      pid = backend(mode, %Limits{}, options)
      assert :ok = Backend.submit(pid, request(id, %{order: "123"}))
      assert_receive {:parlora_event, %Event{type: :request_uncertain, request_id: ^id}}, 5_000
      for _step <- 1..expected, do: assert_receive({:legion_model_call, ^id, _, _})
      refute_receive {:legion_model_call, ^id, _, _}, 20
    end
  end

  test "required native calls, result size and command records are finite" do
    for mode <- [:missing, :oversized] do
      pid = backend(mode)
      id = Atom.to_string(mode)
      assert :ok = Backend.submit(pid, request(id, %{order: "123"}))
      assert_receive {:parlora_event, %Event{type: :request_uncertain, request_id: ^id}}, 5_000
    end

    pid = backend(:complete, %Limits{max_records: 2})
    req = request("retained", %{order: "123"})
    assert :ok = Backend.submit(pid, req)
    assert_receive {:parlora_event, %Event{type: :request_completed}}, 5_000
    assert :ok = Backend.close(pid, "close", :finish)
    assert :ok = Backend.submit(pid, req)

    assert {:error, %{code: :backpressure}} =
             Backend.submit(pid, request("full", %{order: "124"}))

    assert map_size(:sys.get_state(pid).commands.entries) == 2
  end

  test "multi-iteration execution caches native evidence and cancellation races have one terminal" do
    pid = backend(:multi_step)
    assert :ok = Backend.submit(pid, request("multi", %{order: "123"}))
    assert_receive {:parlora_event, %Event{type: :request_completed}}, 5_000
    assert_receive {:legion_model_call, "multi", 0, _}
    assert_receive {:legion_model_call, "multi", 1, _}
    assert_receive {:native_operation, "multi", _}
    refute_receive {:native_operation, "multi", _}, 20

    pid = backend()
    assert :ok = Backend.submit(pid, request("race", %{order: "123", gate: true}))
    assert_receive {:lookup_waiting, "123", collector}, 5_000
    send(collector, :finish)
    reply = Backend.cancel(pid, "race-cancel", "race", :caller)
    assert reply == :ok or match?({:error, %{code: :not_ready}}, reply)
    assert Backend.cancel(pid, "race-cancel", "race", :caller) == reply

    assert_receive {:parlora_event, %Event{type: terminal, request_id: "race"}}
                   when terminal in [:request_completed, :request_uncertain],
                   5_000

    refute_receive {:parlora_event, %Event{type: :request_completed, request_id: "race"}}, 20
    refute_receive {:parlora_event, %Event{type: :request_uncertain, request_id: "race"}}, 20
    assert :sys.get_state(pid).jobs == %{}
  end

  test "owner shutdown stops every request-owned process" do
    observer = self()

    owner =
      spawn(fn ->
        {:ok, pid} =
          Backend.start_link(
            %{init(%Limits{}) | event_sink: observer},
            LegionModel.options(observer)
          )

        send(observer, {:owned_backend, pid})

        receive do
          :stop -> exit(:shutdown)
        end
      end)

    assert_receive {:owned_backend, pid}
    assert :ok = Backend.submit(pid, request("owner", %{order: "123", gate: true}))
    assert_receive {:legion_model_call, "owner", _, agent}, 5_000
    assert_receive {:lookup_waiting, "123", collector}
    {:monitored_by, [sandbox | _]} = Process.info(collector, :monitored_by)
    refs = Enum.map([pid, agent, collector, sandbox], &Process.monitor/1)
    send(owner, :stop)
    Enum.each(refs, fn ref -> assert_receive {:DOWN, ^ref, :process, _, _}, 2_000 end)
  end

  test "a mapped cancellation cannot claim that stopping local work cancelled an external action" do
    factory = LegionModel.options(self())[:execution]

    execution = fn request ->
      factory.(request) |> Map.put(:result, fn _ -> %{status: :cancelled, facts: %{}} end)
    end

    pid = backend(:complete, %Limits{}, execution: execution)
    assert :ok = Backend.submit(pid, request("invalid-cancellation", %{order: "123"}))

    assert_receive {:parlora_event,
                    %Event{type: :request_uncertain, payload: %{reason: :invalid_result}}},
                   5_000

    refute_received {:parlora_event, %Event{type: :request_cancelled}}
  end

  defp backend(mode \\ :complete, limits \\ %Limits{}, extra \\ []) do
    start_supervised!(%{
      id: {Backend, make_ref()},
      start:
        {Backend, :start_link,
         [init(limits), Keyword.merge(LegionModel.options(self(), mode), extra)]},
      restart: :temporary
    })
  end

  defp init(limits),
    do: %AdapterInit{
      session_id: "session",
      adapter_id: "backend",
      generation: 0,
      event_sink: self(),
      limits: limits
    }

  defp request(id, input),
    do: %BackendRequest{
      id: id,
      task_id: "task",
      task_revision: 2,
      provider_generation: 7,
      input: input
    }
end
