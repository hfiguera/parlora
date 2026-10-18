defmodule Parlora.JidoTest do
  use ExUnit.Case, async: true
  alias Parlora.{AdapterInit, BackendRequest, Event, ID, Limits}
  alias Parlora.Backends.Jido, as: Backend
  alias Parlora.TestSupport.LookupAgent

  for malformed <- [
        :status,
        :facts,
        :summary,
        :oversized,
        :missing_status,
        :not_a_map,
        :raise,
        :throw
      ] do
    @malformed malformed
    test "#{malformed} mapper output is isolated from concurrent requests and retained as uncertain at close" do
      mapper = fn %{result: result} ->
        if result.order == "123",
          do: malformed(@malformed),
          else: %{status: :completed, facts: result, summary: "Order 124"}
      end

      pid = backend(mapper)
      bad = request("bad", "123")
      good = request("good", "124")
      assert :ok = Backend.submit(pid, bad)
      assert :ok = Backend.submit(pid, good)
      assert_receive {:lookup_waiting, "123", bad_worker}
      assert_receive {:lookup_waiting, "124", good_worker}
      send(bad_worker, :finish)

      assert_receive {:parlora_event,
                      %Event{
                        type: :request_uncertain,
                        request_id: "bad",
                        payload: %{
                          reason: :invalid_result,
                          outcome: :unknown,
                          task_id: "task-bad",
                          task_revision: 1,
                          provider_generation: 0
                        }
                      }}

      assert Process.alive?(pid)
      assert {:ok, _caps} = Backend.capabilities(pid)
      assert Map.keys(:sys.get_state(pid).jobs) == ["good"]
      send(good_worker, :finish)

      assert_receive {:parlora_event,
                      %Event{
                        type: :request_completed,
                        request_id: "good",
                        payload: %{facts: %{order: "124"}}
                      }}

      assert :ok = Backend.submit(pid, bad)
      refute_receive {:lookup_waiting, "123", _replay}, 20
      refute_received {:parlora_event, %Event{type: :request_completed, request_id: "bad"}}
      refute_received {:parlora_event, %Event{type: :request_failed, request_id: "bad"}}
      refute_received {:parlora_event, %Event{type: :request_cancelled, request_id: "bad"}}
      assert :sys.get_state(pid).jobs == %{}
      assert :ok = Backend.close(pid, "close", :finish)

      assert_receive {:parlora_event,
                      %Event{type: :closed, payload: %{uncertain_requests: ["bad"]}}}
    end
  end

  test "an explicit cancelled mapping remains a cancelled result with optional facts" do
    pid = backend(fn _terminal -> %{status: :cancelled, summary: "Explicit mapped outcome"} end)
    assert :ok = Backend.submit(pid, request("cancelled", "123"))
    assert_receive {:lookup_waiting, "123", worker}
    send(worker, :finish)

    assert_receive {:parlora_event,
                    %Event{
                      type: :request_cancelled,
                      request_id: "cancelled",
                      payload: %{status: :cancelled, facts: %{}}
                    }}

    refute_received {:parlora_event, %Event{type: :request_uncertain}}
  end

  test "a verified failure keeps its error and never becomes an uncertain outcome" do
    error = Parlora.Error.new(:invalid_argument, "Verified native failure")
    pid = backend(fn _terminal -> %{status: :failed, facts: %{}, error: error} end)
    assert :ok = Backend.submit(pid, request("failed", "123"))
    assert_receive {:lookup_waiting, "123", worker}
    send(worker, :finish)

    assert_receive {:parlora_event,
                    %Event{type: :request_failed, request_id: "failed", payload: %{error: ^error}}}

    refute_received {:parlora_event, %Event{type: :request_uncertain}}
  end

  test "concurrent requests have independent agents and correlated terminal results" do
    start_supervised!({Jido, name: Parlora.TestJido})

    init = %AdapterInit{
      session_id: ID.new(),
      adapter_id: ID.new(),
      generation: 0,
      event_sink: self(),
      limits: %Limits{}
    }

    mapper = fn %{status: status, result: result} ->
      %{status: status, facts: result, summary: "Order #{result.order} arrives tomorrow"}
    end

    pid =
      start_supervised!(%{
        id: Backend,
        start:
          {Backend, :start_link,
           [init, [agent: LookupAgent, result: mapper, agent_options: [jido: Parlora.TestJido]]]},
        restart: :temporary
      })

    assert_receive {:parlora_event, %Event{type: :ready}}

    first = %BackendRequest{
      id: "r1",
      task_id: "task",
      task_revision: 1,
      provider_generation: 0,
      input: %{order: "123", delay_ms: 60}
    }

    second = %{first | id: "r2", task_revision: 2, input: %{order: "124", delay_ms: 5}}
    assert :ok = Backend.submit(pid, first)
    assert :ok = Backend.submit(pid, second)
    assert :ok = Backend.submit(pid, second)

    assert_receive {:parlora_event,
                    %Event{
                      type: :request_completed,
                      request_id: "r2",
                      payload: %{facts: %{order: "124"}}
                    }},
                   2_000

    assert_receive {:parlora_event,
                    %Event{
                      type: :request_completed,
                      request_id: "r1",
                      payload: %{facts: %{order: "123"}}
                    }},
                   2_000

    assert {:error, %{code: :unsupported}} = Backend.cancel(pid, "cancel", "r1", :test)
    assert :ok = Backend.close(pid, "close", :finish)
    assert_receive {:parlora_event, %Event{type: :closed}}
    workers = :sys.get_state(pid).workers
    ref = Process.monitor(workers)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^workers, :normal}
  end

  for failure <- [:raise, :throw, :exit, :invalid] do
    @failure failure
    test "#{failure} cancellation mapping leaves concurrent work observed" do
      observer = self()

      pid =
        backend(&completed/1,
          cancel_signal: fn request, reason ->
            send(observer, {:cancel_mapping, request.id, reason})
            cancel_failure(@failure)
          end
        )

      first = request("first", "123")
      other = request("other", "124")
      assert :ok = Backend.submit(pid, first)
      assert :ok = Backend.submit(pid, other)
      assert_receive {:lookup_waiting, "123", first_worker}
      assert_receive {:lookup_waiting, "124", other_worker}
      assert_receive {:parlora_event, %Event{type: :request_started, request_id: "first"}}
      assert_receive {:parlora_event, %Event{type: :request_started, request_id: "other"}}

      assert :ok = Backend.cancel(pid, "cancel", "first", :test)
      assert_receive {:cancel_mapping, "first", :test}

      assert_receive {:parlora_event,
                      %Event{
                        type: :cancellation_rejected,
                        command_id: "cancel",
                        request_id: "first",
                        payload: %{error: %{code: :adapter_failed}}
                      }}

      assert {:ok, _caps} = Backend.capabilities(pid)
      assert :ok = Backend.cancel(pid, "cancel", "first", :test)
      refute_receive {:cancel_mapping, _, _}, 20
      assert {:error, %{code: :invalid_argument}} = Backend.cancel(pid, "cancel", "other", :test)

      send(other_worker, :finish)
      assert_receive {:parlora_event, %Event{type: :request_completed, request_id: "other"}}
      send(first_worker, :finish)
      assert_receive {:parlora_event, %Event{type: :request_completed, request_id: "first"}}
      refute_received {:parlora_event, %Event{type: :request_cancelled}}
      refute_received {:parlora_event, %Event{type: :request_uncertain}}
      assert :ok = Backend.close(pid, "close", :finish)
      assert_receive {:parlora_event, %Event{type: :closed, payload: %{uncertain_requests: []}}}
    end
  end

  test "blocked cancellation mapping is bounded while other requests complete" do
    observer = self()

    pid =
      backend(
        &completed/1,
        [
          cancel_signal: fn _request, _reason ->
            send(observer, {:mapping_waiting, self()})

            receive do
              :release -> Jido.Signal.new!("parlora.cancel", %{}, %{source: "/test"})
            end
          end
        ],
        %Limits{cancellation_timeout_ms: 1_000}
      )

    assert :ok = Backend.submit(pid, request("first", "123"))
    assert :ok = Backend.submit(pid, request("other", "124"))
    assert_receive {:lookup_waiting, "123", first_worker}
    assert_receive {:lookup_waiting, "124", other_worker}
    assert_receive {:parlora_event, %Event{type: :request_started, request_id: "first"}}
    assert :ok = Backend.cancel(pid, "cancel", "first", :test)
    assert_receive {:mapping_waiting, mapper}
    ref = Process.monitor(mapper)
    pending_ref = :sys.get_state(pid).cancellations["cancel"].task.ref
    assert :ok = Backend.cancel(pid, "cancel", "first", :test)
    assert {:error, %{code: :backpressure}} = Backend.cancel(pid, "another", "first", :test)
    assert {:ok, _caps} = Backend.capabilities(pid)
    send(other_worker, :finish)
    assert_receive {:parlora_event, %Event{type: :request_completed, request_id: "other"}}

    assert_receive {:parlora_event,
                    %Event{
                      type: :cancellation_rejected,
                      command_id: "cancel",
                      payload: %{error: %{code: :timeout}}
                    }},
                   2_000

    assert_receive {:DOWN, ^ref, :process, ^mapper, :killed}
    send(pid, {pending_ref, {:ok, Jido.Signal.new!("parlora.cancel", %{}, %{source: "/test"})}})
    send(pid, {:cancellation_timeout, "cancel", pending_ref})
    assert {:ok, _caps} = Backend.capabilities(pid)
    send(first_worker, :finish)
    assert_receive {:parlora_event, %Event{type: :request_completed, request_id: "first"}}
    refute_received {:parlora_event, %Event{type: :cancellation_requested}}
    refute_received {:parlora_event, %Event{type: :request_cancelled}}
  end

  test "finishing a request kills its pending cancellation mapping" do
    observer = self()

    pid =
      backend(&completed/1,
        cancel_signal: fn _request, _reason ->
          send(observer, {:mapping_waiting, self()})

          receive do
            :release -> Jido.Signal.new!("parlora.cancel", %{}, %{source: "/test"})
          end
        end
      )

    assert :ok = Backend.submit(pid, request("first", "123"))
    assert_receive {:lookup_waiting, "123", worker}
    assert_receive {:parlora_event, %Event{type: :request_started, request_id: "first"}}
    assert :ok = Backend.cancel(pid, "cancel", "first", :test)
    assert_receive {:mapping_waiting, mapper}
    ref = Process.monitor(mapper)
    send(worker, :finish)
    assert_receive {:parlora_event, %Event{type: :request_completed, request_id: "first"}}
    assert_receive {:parlora_event, %Event{type: :cancellation_rejected, command_id: "cancel"}}
    assert_receive {:DOWN, ^ref, :process, ^mapper, :killed}
    assert :sys.get_state(pid).cancellations == %{}
    refute_received {:parlora_event, %Event{type: :cancellation_requested}}
  end

  test "a valid cancellation signal is admitted once without claiming confirmed cancellation" do
    observer = self()

    pid =
      backend(&completed/1,
        cancel_signal: fn request, _reason ->
          send(observer, {:cancel_mapping, request.id})
          Jido.Signal.new!("parlora.cancel", %{}, %{source: "/test"})
        end
      )

    assert :ok = Backend.submit(pid, request("first", "123"))
    assert_receive {:lookup_waiting, "123", worker}
    assert_receive {:parlora_event, %Event{type: :request_started, request_id: "first"}}
    assert :ok = Backend.cancel(pid, "cancel", "first", :test)
    assert_receive {:cancel_mapping, "first"}

    assert_receive {:parlora_event,
                    %Event{
                      type: :cancellation_requested,
                      command_id: "cancel",
                      request_id: "first",
                      payload: %{outcome: :requested}
                    }}

    assert :ok = Backend.cancel(pid, "cancel", "first", :test)
    refute_receive {:cancel_mapping, _}, 20
    refute_received {:parlora_event, %Event{type: :request_cancelled}}
    send(worker, :finish)
  end

  test "formatted diagnostics redact configured credentials, pending requests and errors" do
    secret = "synthetic-backend-credential"
    private = "synthetic-private-request"

    pid =
      backend(&completed/1,
        agent_options: [jido: Parlora.TestJido, initial_state: %{last_answer: %{key: secret}}]
      )

    request = request("first", "123")
    request = %{request | input: Map.put(request.input, :private, private)}
    assert :ok = Backend.submit(pid, request)
    assert_receive {:lookup_waiting, "123", worker}
    state = :sys.get_state(pid)
    assert state.options[:agent_options][:initial_state].last_answer.key == secret
    assert state.jobs["first"].request.input.private == private
    status = inspect(:sys.get_status(pid), limit: :infinity)
    refute status =~ secret
    refute status =~ private

    formatted =
      Backend.format_status(%{
        state: state,
        message: request,
        reason: RuntimeError.exception(secret)
      })

    assert formatted == %{state: :redacted, message: :redacted, reason: :redacted}
    send(worker, :finish)
    assert_receive {:parlora_event, %Event{type: :request_completed, request_id: "first"}}
  end

  test "a killed cancellation mapper rejects its command without losing the request" do
    observer = self()

    pid =
      backend(&completed/1,
        cancel_signal: fn _request, _reason ->
          send(observer, {:mapping_waiting, self()})

          receive do
            :release -> :invalid
          end
        end
      )

    assert :ok = Backend.submit(pid, request("first", "123"))
    assert_receive {:lookup_waiting, "123", worker}
    assert_receive {:parlora_event, %Event{type: :request_started, request_id: "first"}}
    assert :ok = Backend.cancel(pid, "cancel", "first", :test)
    assert_receive {:mapping_waiting, mapper}
    Process.exit(mapper, :kill)

    assert_receive {:parlora_event,
                    %Event{
                      type: :cancellation_rejected,
                      command_id: "cancel",
                      payload: %{error: %{code: :adapter_failed}}
                    }}

    send(worker, :finish)
    assert_receive {:parlora_event, %Event{type: :request_completed, request_id: "first"}}
    assert :sys.get_state(pid).cancellations == %{}
  end

  test "cancel-close stops a blocked mapper at the shutdown deadline" do
    observer = self()

    pid =
      backend(
        &completed/1,
        [
          cancel_signal: fn _request, _reason ->
            send(observer, {:mapping_waiting, self()})

            receive do
              :release -> :invalid
            end
          end
        ],
        %Limits{shutdown_timeout_ms: 500, cancellation_timeout_ms: 5_000}
      )

    assert :ok = Backend.submit(pid, request("first", "123"))
    assert_receive {:lookup_waiting, "123", worker}
    assert_receive {:parlora_event, %Event{type: :request_started, request_id: "first"}}
    assert :ok = Backend.close(pid, "close", :cancel)
    assert_receive {:mapping_waiting, mapper}
    ref = Process.monitor(mapper)
    assert {:ok, _caps} = Backend.capabilities(pid)

    assert_receive {:parlora_event,
                    %Event{
                      type: :closed,
                      command_id: "close",
                      payload: %{uncertain_requests: ["first"]}
                    }},
                   2_000

    assert_receive {:DOWN, ^ref, :process, ^mapper, :killed}
    refute_received {:parlora_event, %Event{type: :cancellation_requested}}
    refute_received {:parlora_event, %Event{type: :request_cancelled}}
    send(worker, :finish)
  end

  test "invalid cancellation hooks are rejected before advertising support" do
    init = %AdapterInit{
      session_id: ID.new(),
      adapter_id: ID.new(),
      generation: 0,
      event_sink: self(),
      limits: %Limits{}
    }

    for invalid <- [nil, :invalid, fn _request -> :invalid end] do
      assert {:error, %{code: :invalid_argument}} =
               Backend.start_link(init,
                 agent: LookupAgent,
                 result: &completed/1,
                 cancel_signal: invalid
               )
    end
  end

  defp backend(mapper, options \\ [], limits \\ %Limits{}) do
    start_supervised!({Jido, name: Parlora.TestJido})

    init = %AdapterInit{
      session_id: ID.new(),
      adapter_id: ID.new(),
      generation: 0,
      event_sink: self(),
      limits: limits
    }

    start_supervised!(%{
      id: Backend,
      start:
        {Backend, :start_link,
         [
           init,
           Keyword.merge(
             [agent: LookupAgent, result: mapper, agent_options: [jido: Parlora.TestJido]],
             options
           )
         ]},
      restart: :temporary
    })
  end

  defp request(id, order),
    do: %BackendRequest{
      id: id,
      task_id: "task-" <> id,
      task_revision: 1,
      provider_generation: 0,
      input: %{order: order, gate: self()}
    }

  defp malformed(:status), do: %{status: :unexpected_status, facts: %{}}
  defp malformed(:facts), do: %{status: :completed, facts: []}
  defp malformed(:summary), do: %{status: :completed, facts: %{}, summary: 123}
  defp malformed(:oversized), do: %{status: :completed, facts: %{data: :binary.copy("x", 65_537)}}
  defp malformed(:missing_status), do: %{facts: %{}}
  defp malformed(:not_a_map), do: :not_a_map
  defp malformed(:raise), do: raise("synthetic mapper error")
  defp malformed(:throw), do: throw(:synthetic_mapper_error)

  defp completed(%{result: result}), do: %{status: :completed, facts: result}
  defp cancel_failure(:raise), do: raise("synthetic cancellation error")
  defp cancel_failure(:throw), do: throw(:synthetic_cancellation_error)
  defp cancel_failure(:exit), do: exit(:synthetic_cancellation_error)
  defp cancel_failure(:invalid), do: :invalid
end
