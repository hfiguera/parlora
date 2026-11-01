defmodule BookingDesk.IdentityExtractorTest do
  use ExUnit.Case, async: false
  alias BookingDesk.Identity.Extractor

  defp state(
         text \\ "Jamie Rivera, March 12th, 1990.",
         session \\ "test",
         generation \\ 0,
         cursor \\ 1
       ) do
    %{
      dialogue: [%{speaker: :user, text: text}],
      latest_user: text,
      interpretation_binding: %{
        session_id: session,
        provider_generation: generation,
        caller_cursor: cursor
      }
    }
  end

  defp start(opts), do: start_supervised!({Extractor, [name: nil] ++ opts})

  defp ready(server, state, tries \\ 50) do
    case Extractor.check(state, server) do
      :pending when tries > 0 ->
        Process.sleep(10)
        ready(server, state, tries - 1)

      value ->
        value
    end
  end

  test "debounces new fragments, reuses a finished extraction and strips local bindings" do
    parent = self()

    server =
      start(
        debounce_ms: 20,
        evaluator: fn input ->
          send(parent, {:evaluated, input})
          {:ok, %{name: "jamie rivera", dob: "1990-03-12"}}
        end
      )

    assert :pending = Extractor.check(state("Jamie"), server)
    full = state()
    assert :pending = Extractor.check(full, server)
    assert_receive {:evaluated, input}
    assert input.latest_user == full.latest_user
    refute Map.has_key?(input, :interpretation_binding)
    assert {:ok, %{name: "jamie rivera"}} = ready(server, full)
    assert {:ok, _} = Extractor.check(full, server)
    refute_receive {:evaluated, _}, 30
  end

  test "caller changes and new generations cancel work; stale results cannot authorize lookup" do
    parent = self()

    server =
      start(
        debounce_ms: 0,
        evaluator: fn input ->
          send(parent, {:started, self(), input.latest_user})

          receive do
            :finish -> {:ok, %{name: "jamie rivera", dob: "1990-03-12"}}
          end
        end
      )

    original = state()
    assert :pending = Extractor.check(original, server)
    assert_receive {:started, old_pid, _}
    old_ref = :sys.get_state(server).entries[{"test", 0}].job.task.ref
    changed = state("Actually, Alex Morgan, July 24th, 1985.", "test", 0, 2)
    assert :pending = Extractor.check(changed, server)
    refute Process.alive?(old_pid)
    assert_receive {:started, current_pid, _}
    send(server, {old_ref, {:ok, %{name: "jamie rivera", dob: "1990-03-12"}}})
    assert :pending = Extractor.check(changed, server)
    generation = state(changed.latest_user, "test", 1, 2)
    assert :pending = Extractor.check(generation, server)
    refute Process.alive?(current_pid)
    assert {:error, :stale} = Extractor.check(original, server)
    assert_receive {:started, _, _}
    assert :pending = Extractor.check(generation, server)
    assert Map.keys(:sys.get_state(server).entries) == [{"test", 1}]
  end

  test "timeouts are cached and the per-session evaluation budget is bounded" do
    parent = self()

    server =
      start(
        debounce_ms: 0,
        timeout_ms: 20,
        max_evaluations: 1,
        evaluator: fn _ ->
          send(parent, :started)

          receive do
            :never -> :ok
          end
        end
      )

    s = state()
    assert :pending = Extractor.check(s, server)
    assert_receive :started
    assert {:error, :unavailable} = ready(server, s)
    assert {:error, :unavailable} = Extractor.check(s, server)
    next = state("A corrected reply", "test", 0, 2)
    assert :pending = Extractor.check(next, server)
    assert {:error, :unavailable} = ready(server, next)
    refute_receive :started, 30
  end

  test "extraction diagnostics distinguish invalid evidence without recording demographics" do
    parent = self()
    handler = "extractor-diagnostics-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:booking_desk, :extraction, :stop],
      fn _, measurements, metadata, _ -> send(parent, {:extraction, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    server = start(debounce_ms: 0, evaluator: fn _ -> {:error, :invalid_extraction} end)
    s = state()
    assert :pending = Extractor.check(s, server)
    assert {:error, :invalid_extraction} = ready(server, s)

    assert_receive {:extraction, %{attempt: 1},
                    %{field: :identity, outcome: :error, reason: :invalid_extraction} = metadata}

    refute inspect(metadata) =~ "Jamie"
    refute Map.has_key?(metadata, :dob)
    assert {:error, :invalid_extraction} = Extractor.check(s, server)
    refute_receive {:extraction, _, _}, 30
  end

  test "oversized input is rejected and at most sixteen session entries are retained" do
    server = start(debounce_ms: 60_000)

    assert {:error, :invalid_extraction} =
             Extractor.check(state(String.duplicate("a", 8_001)), server)

    for id <- 1..17,
        do: assert(:pending == Extractor.check(state("name and DOB", "session-#{id}"), server))

    assert map_size(:sys.get_state(server).entries) == 16
    assert Map.has_key?(:sys.get_state(server).entries, {"session-17", 0})
  end
end
