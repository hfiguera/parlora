defmodule BookingDesk.ReadbackTest do
  use ExUnit.Case, async: true
  alias BookingDesk.Readback

  @expected %{date: "2026-11-05", time: "10:15", clinician: "Dr. Lee", operation: "book"}

  defp input do
    %{
      settled: true,
      revision: 1,
      generation: 0,
      text: "Thursday November fifth at ten fifteen AM with Dr. Lee. Shall we book that?",
      proposal: %{
        id: "proposal-a",
        patient: "p_1002",
        revision: 4,
        slot: "2026-11-05T10:15:00",
        clinician: "Dr. Lee",
        status: "pending",
        change: "book",
        expires: 200
      }
    }
  end

  defp gate(opts \\ []) do
    owner = self()

    judge = fn state ->
      send(owner, {:judging, self(), state})

      receive do
        {:answer, result} -> result
      end
    end

    start_supervised!({Readback, Keyword.merge([judge: judge, now: fn -> 100 end], opts)},
      id: make_ref()
    )
  end

  defp await(fun, remaining \\ 100)

  defp await(fun, remaining) when remaining > 0 do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          await(fun, remaining - 1)
        )
  end

  defp await(_, 0), do: flunk("asynchronous readback did not settle")

  defp finish(gate, worker, result) do
    send(worker, {:answer, result})
    await(fn -> :sys.get_state(gate).job == nil end)
  end

  test "the check is nonblocking, single flight and gives JEV only speech and expected appointment fields" do
    pid = gate()
    snapshot = input()
    assert :waiting = Readback.check(pid, snapshot)
    assert_receive {:judging, worker, state}
    assert state == %{assistant_text: snapshot.text, expected: @expected}
    assert :waiting = Readback.check(pid, snapshot)
    refute_receive {:judging, _, _}, 10
    finish(pid, worker, {:ok, :ready})
    assert {:ready, evidence} = Readback.check(pid, snapshot)
    assert evidence.evaluator == "jev"
    assert evidence.proposal == "proposal-a"
    assert evidence.proposal_revision == 4
    assert evidence.transcript_revision == 1

    assert evidence.transcript_sha256 ==
             :crypto.hash(:sha256, snapshot.text) |> Base.encode16(case: :lower)

    assert {:ready, ^evidence} = Readback.check(pid, snapshot)
  end

  test "a transcript, provider generation or proposal change cancels the old evaluation and rejects late replies" do
    for change <- [
          fn s -> %{s | text: s.text <> " Actually, wait.", revision: 2} end,
          fn s -> %{s | generation: 1} end,
          fn s -> put_in(s, [:proposal, :revision], 5) end
        ] do
      pid = gate()
      assert :waiting = Readback.check(pid, input())
      assert_receive {:judging, old, _}
      old_ref = :sys.get_state(pid).job.task.ref
      monitor = Process.monitor(old)
      newer = change.(input())
      assert :waiting = Readback.check(pid, newer)
      assert_receive {:DOWN, ^monitor, :process, ^old, :killed}
      assert_receive {:judging, worker, _}
      send(pid, {old_ref, {:ok, :ready}})
      send(pid, {:deadline, old_ref})
      assert :waiting = Readback.check(pid, newer)
      finish(pid, worker, {:error, :uncertain})
      assert :waiting = Readback.check(pid, newer)
    end
  end

  test "cached acceptance cannot survive a new proposal, renewed speech or expiration" do
    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, 100)
    pid = gate(now: fn -> :atomics.get(clock, 1) end)
    assert :waiting = Readback.check(pid, input())
    assert_receive {:judging, worker, _}
    finish(pid, worker, {:ok, :ready})
    assert {:ready, _} = Readback.check(pid, input())
    changed = put_in(input(), [:proposal, :id], "proposal-b")
    assert :waiting = Readback.check(pid, changed)
    assert_receive {:judging, second, _}
    finish(pid, second, {:ok, :ready})
    assert {:ready, _} = Readback.check(pid, changed)
    assert :waiting = Readback.check(pid, %{changed | settled: false})
    refute match?({:ready, _}, Readback.check(pid, changed))
    :atomics.put(clock, 1, 201)
    assert :waiting = Readback.check(pid, %{changed | revision: 2})
    refute_receive {:judging, _, _}, 10
  end

  test "no proposal, unavailable playout, an expired proposal or oversized text starts no judgment" do
    pid = gate()

    for s <- [
          put_in(input(), [:proposal], nil),
          %{input() | settled: false},
          put_in(input(), [:proposal, :expires], 99),
          %{input() | text: String.duplicate("x", 8001)},
          put_in(input(), [:proposal, :status], "superseded")
        ] do
      assert :waiting = Readback.check(pid, s)
    end

    refute_receive {:judging, _, _}, 10
  end

  test "expiration rejects a previously accepted answer even when the transcript is unchanged" do
    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, 100)
    pid = gate(now: fn -> :atomics.get(clock, 1) end)
    assert :waiting = Readback.check(pid, input())
    assert_receive {:judging, worker, _}
    finish(pid, worker, {:ok, :ready})
    assert {:ready, _} = Readback.check(pid, input())
    :atomics.put(clock, 1, 200)
    assert :waiting = Readback.check(pid, input())
    refute_receive {:judging, _, _}, 10
  end

  test "an uncertain result is not retried on each poll and the per-run evaluation budget is bounded" do
    pid = gate(max_evaluations: 2)

    for revision <- 1..2 do
      s = %{input() | revision: revision}
      assert :waiting = Readback.check(pid, s)
      assert_receive {:judging, worker, _}
      finish(pid, worker, {:error, :uncertain})
      assert :waiting = Readback.check(pid, s)
      refute_receive {:judging, _, _}, 10
    end

    assert :waiting = Readback.check(pid, %{input() | revision: 3})
    refute_receive {:judging, _, _}, 10
  end

  test "deadline kills a stalled judgment and a late positive reply cannot approve" do
    pid = gate(timeout_ms: 30)
    assert :waiting = Readback.check(pid, input())
    assert_receive {:judging, worker, _}
    job = :sys.get_state(pid).job
    monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    send(pid, {job.task.ref, {:ok, :ready}})
    assert :waiting = Readback.check(pid, input())
    refute_receive {:judging, _, _}, 10
  end

  @tag capture_log: true
  test "worker failure withholds approval and stopping the gate cleans up in-flight work" do
    pid = gate(judge: fn _ -> exit(:readback_failure) end)
    assert :waiting = Readback.check(pid, input())
    await(fn -> :sys.get_state(pid).job == nil end)
    assert :waiting = Readback.check(pid, input())
    other = gate()
    assert :waiting = Readback.check(other, input())
    assert_receive {:judging, worker, _}
    monitor = Process.monitor(worker)
    GenServer.stop(other)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
  end

  test "JEV must match every field and permission with sufficient selected-label probability" do
    answers =
      Map.new(Map.put(@expected, :permission, "approval") |> Map.delete(:operation), fn {k, v} ->
        {to_string(k), %{choice: v, probabilities: %{v => 0.99}}}
      end)

    assert {:ok, :ready} = Readback.decode(answers, @expected)

    for {key, wrong} <- [
          {"permission", "not_approval"},
          {"permission", "unclear"},
          {"date", "other"},
          {"time", "missing"},
          {"clinician", "conflicting"}
        ] do
      changed = Map.put(answers, key, %{choice: wrong, probabilities: %{wrong => 1.0}})
      assert {:error, :uncertain} = Readback.decode(changed, @expected)
    end

    for value <- [0.84, 1.01, "0.99", nil] do
      changed = put_in(answers, ["permission", :probabilities, "approval"], value)
      assert {:error, :uncertain} = Readback.decode(changed, @expected)
    end

    assert {:error, :uncertain} = Readback.decode(Map.delete(answers, "time"), @expected)

    assert {:ok, :ready} =
             Readback.decode(
               put_in(answers, ["permission", :probabilities, "approval"], 0.85),
               @expected
             )
  end
end
