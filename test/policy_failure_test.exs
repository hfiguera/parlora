defmodule Parlora.PolicyFailureTest do
  use ExUnit.Case, async: true
  alias Parlora.{ContextDecision, Error, Event}

  alias Parlora.TestSupport.{
    ControlledPolicy,
    FakeBackend,
    MemoryAudio,
    MemoryChannel,
    MemoryProvider
  }

  for failure <- [:timeout, :crash, :error] do
    @failure failure
    test "#{failure} rechecks the latest correction without replaying work or delivering stale results" do
      {session, provider, backend} = session()
      request = start_work(provider)
      transcript(provider, "actually order 124")
      assert_receive {:policy, failing, _snapshot, _trigger}
      work = :sys.get_state(session).policy_task
      transcript(provider, "please check that")
      assert :ok = FakeBackend.complete(backend, request, "Obsolete order 123")
      assert_receive {:parlora_event, %Event{type: :request_completed}}
      assert Parlora.status(session).jobs[request.id].delivery == :awaiting_interpretation

      fail(session, failing, work, @failure)

      assert_receive {:parlora_event,
                      %Event{type: :policy_failed, payload: %{attempt: 1, retry?: true}}}

      assert_receive {:policy, retry, snapshot, _trigger}
      assert Enum.any?(snapshot.transcripts, &(&1.delta == "please check that"))
      refute_received {:submitted, _extra}
      refute_received {:context, _obsolete}

      # Old task results, DOWNs and deadline messages cannot retire the new task.
      send(session, {work.ref, {:ok, []}})
      send(session, {:DOWN, work.ref, :process, failing, :killed})
      send(session, {:policy_timeout, work.ref})
      assert :sys.get_state(session).policy_task.pid == retry

      send(
        retry,
        {:decisions,
         [
           %ContextDecision{
             kind: :supersede_task,
             task_id: request.task_id,
             expected_task_revision: 1,
             input: %{order: "124"}
           }
         ]}
      )

      assert_receive {:submitted, corrected}
      assert corrected.task_id == request.task_id
      assert corrected.task_revision == 2
      assert corrected.input == %{order: "124"}
      assert_receive {:parlora_event, %Event{type: :stale_result, request_id: old_id}}
      assert old_id == request.id
      assert :ok = FakeBackend.complete(backend, corrected, "Current order 124")
      assert_receive {:context, %{content: "Current order 124", task_revision: 2}}
      refute_receive {:context, %{content: "Obsolete order 123"}}, 20
      refute_receive {:submitted, _extra}, 20
      assert Parlora.status(session).status == :ready
    end

    test "repeated #{failure} closes explicitly even when more context keeps arriving" do
      {session, provider, _backend} = session()
      request = start_work(provider)
      transcript(provider, "actually order 124")
      assert_receive {:policy, first, _snapshot, _trigger}
      fail(session, first, :sys.get_state(session).policy_task, @failure)

      assert_receive {:parlora_event,
                      %Event{type: :policy_failed, payload: %{attempt: 1, retry?: true}}}

      assert_receive {:policy, retry, _snapshot, _trigger}
      work = :sys.get_state(session).policy_task
      transcript(provider, "newer caller context")
      ref = Process.monitor(session)
      fail(session, retry, work, @failure)

      assert_receive {:parlora_event,
                      %Event{type: :policy_failed, payload: %{attempt: 2, retry?: false}}}

      assert_receive {:parlora_event,
                      %Event{source: :session, type: :failed, payload: %{cause: :policy_failed}}}

      assert_receive {:parlora_event,
                      %Event{source: :session, type: :closed, payload: %{jobs: jobs}}}

      assert jobs[request.id] == :uncertain
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}
      refute_received {:policy, _third, _snapshot, _trigger}
      refute_received {:submitted, _extra}
      refute_received {:context, _unverified}
    end
  end

  test "successful interpretation restores the retry budget for a later failure" do
    {session, provider, _backend} = session()
    delegate(provider)
    assert_receive {:policy, first, _snapshot, _trigger}
    send(first, {:result, {:error, Error.new(:timeout, "synthetic")}})
    assert_receive {:policy, retry, _snapshot, _trigger}
    send(retry, {:decisions, []})
    ref = Process.monitor(retry)
    assert_receive {:DOWN, ^ref, :process, ^retry, _normal_or_already_exited}
    eventually(fn -> :sys.get_state(session).policy_task == nil end)
    transcript(provider, "fresh caller context")
    assert_receive {:policy, later, _snapshot, _trigger}
    send(later, {:result, {:error, Error.new(:timeout, "synthetic")}})
    assert_receive {:policy, final, _snapshot, _trigger}
    send(final, {:decisions, []})
    eventually(fn -> :sys.get_state(session).policy_task == nil end)
    assert Parlora.status(session).status == :ready
    refute_received {:parlora_event, %Event{type: :policy_failed, payload: %{attempt: 2}}}
  end

  test "real interpretation deadlines exhaust the retry budget and clean up the session" do
    {session, provider, _backend} = session(policy_timeout_ms: 50)
    ref = Process.monitor(session)
    delegate(provider)
    # The deadline includes task startup; no response before it is required.
    assert_receive {:parlora_event,
                    %Event{type: :policy_failed, payload: %{attempt: 1, retry?: true}}}

    assert_receive {:parlora_event,
                    %Event{type: :policy_failed, payload: %{attempt: 2, retry?: false}}}

    assert_receive {:parlora_event, %Event{source: :session, type: :closed}}
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}
    refute_received {:submitted, _request}
  end

  defp session(limits \\ []) do
    {:ok, session} =
      Parlora.start_session(
        channel: {MemoryChannel, observer: self()},
        provider: {MemoryProvider, observer: self()},
        backend: {FakeBackend, observer: self()},
        context_policy: {ControlledPolicy, observer: self()},
        # Keep the shutdown deadline inside this fixture's one-second assertions.
        limits: Keyword.put_new(limits, :shutdown_timeout_ms, 200),
        event_sink: self()
      )

    on_exit(fn -> if Process.alive?(session), do: Parlora.close(session) end)
    assert_receive {:adapter, :channel, _channel}
    assert_receive {:adapter, :provider, provider}
    assert_receive {:adapter, :backend, backend}
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}
    {session, provider, backend}
  end

  defp start_work(provider) do
    delegate(provider)
    assert_receive {:policy, worker, _snapshot, _trigger}

    send(
      worker,
      {:decisions,
       [%ContextDecision{kind: :start_task, delegation_id: "work", input: %{order: "123"}}]}
    )

    assert_receive {:submitted, request}
    request
  end

  defp delegate(provider),
    do:
      MemoryAudio.inject(provider, :delegation_requested, %{
        id: "work",
        target: :client,
        offset_ms: nil
      })

  defp transcript(provider, delta) do
    assert :ok =
             MemoryAudio.inject(provider, :transcript_delta, %{
               speaker: :user,
               delta: delta,
               start_ms: nil,
               end_ms: nil
             })

    assert_receive {:parlora_event, %Event{type: :transcript_delta, payload: %{delta: ^delta}}}
  end

  defp fail(session, _pid, work, :timeout), do: send(session, {:policy_timeout, work.ref})
  defp fail(_session, pid, _work, :crash), do: Process.exit(pid, :kill)

  defp fail(_session, pid, _work, :error),
    do: send(pid, {:result, {:error, Error.new(:timeout, "synthetic")}})

  defp eventually(fun, retries \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, retries) do
    unless fun.() do
      Process.sleep(10)
      eventually(fun, retries - 1)
    end
  end
end
