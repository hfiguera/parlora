defmodule BookingDesk.RemindersTest do
  use ExUnit.Case, async: false
  alias BookingDesk.{Phone, Reminders, Store}

  setup do
    store = start_supervised!({Store, path: ":memory:", name: :reminder_test_store})

    base = %{
      patient: "p_1002",
      lookup_request: "lookup",
      session: "reminder-test",
      insurance_request: "insurance"
    }

    Store.execute(
      %{operation: "lookup", name: "Jamie Rivera", dob: "1990-03-12", session: base.session},
      "lookup",
      store
    )

    Store.execute(
      Map.merge(base, %{
        operation: "insurance",
        response: "unchanged",
        carrier: "Aetna",
        insurance_revision: 1
      }),
      "insurance",
      store
    )

    Store.execute(
      Map.merge(base, %{
        operation: "availability",
        date: "2026-11-05",
        clinician: "lee",
        cursor: 1
      }),
      "available",
      store
    )

    Store.execute(
      Map.merge(base, %{
        operation: "propose",
        slot: "2026-11-05T10:15:00",
        clinician: "lee",
        revision: 2,
        search_cursor: 1
      }),
      "proposal",
      store
    )

    Store.execute(
      Map.merge(base, %{operation: "confirm", proposal: "proposal", revision: 2}),
      "booked",
      store
    )

    %{store: store, base: Map.put(base, :booking_request, "booked")}
  end

  defp run(ctx, operation, id, extra \\ %{}) do
    state =
      Store.reminder(
        ctx.base.booking_request,
        ctx.base.lookup_request,
        ctx.base.session,
        ctx.store
      )

    input =
      ctx.base
      |> Map.merge(%{operation: operation, reminder_revision: state.request_id})
      |> Map.merge(extra)

    {Store.execute(input, id, ctx.store), input}
  end

  test "Gemini's longer confirmation/reminder burst fits a bounded receive queue" do
    alias Parlora.{AdapterInit, AudioFormat, Limits}
    alias Parlora.Provider.OutputBuffer
    {:ok, limits} = Limits.new(BookingDesk.limits("gemini"))
    assert limits.provider_audio_queue_bytes == 24_000 * 2 * 20
    assert limits.provider_audio_max_age_ms == 21_000
    assert limits.audio_queue_bytes == 9_600

    init = %AdapterInit{
      session_id: "burst",
      adapter_id: "provider",
      generation: 0,
      event_sink: self(),
      audio_format: %AudioFormat{},
      limits: limits
    }

    pcm = :binary.copy(<<1, 0>>, 24_000 * 11)
    assert {:ok, {queue, _}} = OutputBuffer.push(OutputBuffer.new(limits), pcm, init, 0, 0)

    assert {:ok, frames, _} =
             OutputBuffer.read(queue, limits.provider_audio_queue_bytes, limits, 1_000)

    assert Enum.map_join(frames, & &1.data) == pcm
    assert BookingDesk.limits("grok") == [job_timeout_ms: 35_000, policy_timeout_ms: 5_000]
  end

  test "opt-in and exact destination confirmation create one idempotent simulated 24h job", ctx do
    assert Store.reminder_jobs(ctx.store) == []
    {optin, _} = run(ctx, "reminder_opt_in", "consent")
    assert optin["facts"]["reminder"]["last_four"] == "0188"
    refute String.contains?(optin["summary"], "2025550188")
    assert Store.reminder_jobs(ctx.store) == []

    {done, input} =
      run(ctx, "reminder_confirm", "schedule", %{
        destination: "+12025550188",
        readback_verified: true
      })

    assert done["status"] == "completed"
    assert Store.execute(input, "schedule", ctx.store) == done

    assert [["booked", "p_1002", "+12025550188", "2026-11-04T17:15:00Z", "simulated", "schedule"]] =
             Store.reminder_jobs(ctx.store)

    {_, _} =
      run(ctx, "reminder_confirm", "duplicate", %{
        destination: "+12025550188",
        readback_verified: true
      })

    assert length(Store.reminder_jobs(ctx.store)) == 1
  end

  test "new phone remains unsaved until its full readback is approved", ctx do
    run(ctx, "reminder_opt_in", "consent")
    run(ctx, "reminder_change", "changed")
    {candidate, _} = run(ctx, "reminder_number", "candidate", %{phone: "+12025550199"})
    assert candidate["facts"]["reminder"]["status"] == "verify_new"
    db = :sys.get_state(ctx.store)
    assert sql(db, "SELECT phone FROM patients WHERE id='p_1002'") == [["2025550188"]]
    assert Store.reminder_jobs(ctx.store) == []

    {bad, _} =
      run(ctx, "reminder_confirm", "wrong", %{
        destination: "+12025550198",
        readback_verified: true
      })

    assert bad["status"] == "failed"

    {good, _} =
      run(ctx, "reminder_confirm", "right", %{
        destination: "+12025550199",
        readback_verified: true
      })

    assert good["status"] == "completed"
    assert sql(db, "SELECT phone FROM patients WHERE id='p_1002'") == [["+12025550199"]]
  end

  test "missing cell is saved only after a confirmed complete number", ctx do
    db = :sys.get_state(ctx.store)
    Exqlite.Sqlite3.execute(db, "UPDATE patients SET phone=NULL WHERE id='p_1002'")
    run(ctx, "reminder_opt_in", "consent")
    run(ctx, "reminder_number", "number", %{phone: "+12025550199"})
    assert sql(db, "SELECT phone FROM patients WHERE id='p_1002'") == [[nil]]

    {done, _} =
      run(ctx, "reminder_confirm", "scheduled", %{
        destination: "+12025550199",
        readback_verified: true
      })

    assert done["status"] == "completed"
    assert sql(db, "SELECT phone FROM patients WHERE id='p_1002'") == [["+12025550199"]]
    assert length(Store.reminder_jobs(ctx.store)) == 1
  end

  test "a number change cannot bypass opt-in, or reuse another patient's phone", ctx do
    {without_consent, _} = run(ctx, "reminder_change", "premature")
    assert without_consent["status"] == "failed"
    run(ctx, "reminder_opt_in", "consent")
    run(ctx, "reminder_number", "number", %{phone: "+16175559210"})

    {conflict, _} =
      run(ctx, "reminder_confirm", "scheduled", %{
        destination: "+16175559210",
        readback_verified: true
      })

    assert conflict["status"] == "failed"
    assert Store.reminder_jobs(ctx.store) == []

    assert sql(:sys.get_state(ctx.store), "SELECT phone FROM patients WHERE id='p_1002'") == [
             ["2025550188"]
           ]
  end

  test "missing phone is collected; decline keeps booking intact", ctx do
    db = :sys.get_state(ctx.store)
    Exqlite.Sqlite3.execute(db, "UPDATE patients SET phone=NULL WHERE id='p_1002'")
    {result, _} = run(ctx, "reminder_opt_in", "consent")
    assert result["facts"]["reminder"]["status"] == "need_number"
    {invalid, _} = run(ctx, "reminder_number", "short", %{phone: "0188"})
    assert invalid["status"] == "failed"
    {declined, _} = run(ctx, "reminder_decline", "decline")
    assert declined["facts"]["reminder"]["status"] == "declined"
    assert Store.reminder_jobs(ctx.store) == []

    assert Enum.any?(Store.snapshot(ctx.store), fn [id, _, _, status, _] ->
             id == "booked" and status == "booked"
           end)
  end

  test "unmatched session, stale destination, and missing consent cannot schedule", ctx do
    assert Store.reminder("booked", "lookup", "other-session", ctx.store) == nil

    {no_consent, _} =
      run(ctx, "reminder_confirm", "premature", %{
        destination: "+12025550188",
        readback_verified: true
      })

    assert no_consent["status"] == "failed"
    run(ctx, "reminder_opt_in", "consent")

    Exqlite.Sqlite3.execute(
      :sys.get_state(ctx.store),
      "UPDATE patients SET phone='2025550199' WHERE id='p_1002'"
    )

    {stale, _} =
      run(ctx, "reminder_confirm", "stale", %{
        destination: "+12025550188",
        readback_verified: true
      })

    assert stale["status"] == "failed"
    assert Store.reminder_jobs(ctx.store) == []
    run(ctx, "reminder_change", "refresh")
    run(ctx, "reminder_number", "new-number", %{phone: "+12025550199"})

    {recovered, _} =
      run(ctx, "reminder_confirm", "recovered", %{
        destination: "+12025550199",
        readback_verified: true
      })

    assert recovered["status"] == "completed"
  end

  test "cancelling a booked appointment cancels its reminder without another job", ctx do
    run(ctx, "reminder_opt_in", "consent")

    run(ctx, "reminder_confirm", "schedule", %{
      destination: "+12025550188",
      readback_verified: true
    })

    Store.execute(
      Map.merge(ctx.base, %{
        operation: "propose",
        change: "cancel",
        appointment: "booked",
        slot: "",
        revision: 3
      }),
      "cancel-proposal",
      ctx.store
    )

    assert Store.execute(
             Map.merge(ctx.base, %{operation: "confirm", proposal: "cancel-proposal", revision: 3}),
             "cancel",
             ctx.store
           )["status"] == "completed"

    assert [[_, _, _, _, "cancelled", _]] = Store.reminder_jobs(ctx.store)
    assert Store.reminder("booked", "lookup", ctx.base.session, ctx.store) == nil

    assert %{status: "cancelled"} =
             Store.appointment("booked", "lookup", ctx.base.session, ctx.store)

    assert %{status: "cancelled", kind: "cancellation", confirmation: "BD-cancel"} =
             Store.appointment("cancel", "lookup", ctx.base.session, ctx.store)
  end

  test "verified appointment results remain available without dialogue and cannot cross a lookup or call",
       ctx do
    assert %{
             appointment: "booked",
             slot: "2026-11-05T10:15:00",
             status: "booked",
             confirmation: code
           } =
             Store.appointment("booked", "lookup", ctx.base.session, ctx.store)

    assert is_binary(code)
    assert Store.appointment("booked", "another-lookup", ctx.base.session, ctx.store) == nil
    assert Store.appointment("booked", "lookup", "another-call", ctx.store) == nil
    assert Store.appointment("proposal", "lookup", ctx.base.session, ctx.store) == nil
  end

  test "phone extraction requires exact complete caller evidence; readback rejects a wrong suffix" do
    spoken = "two zero two five five five zero one nine nine"
    punctuated = "Two zero two, five five five, zero one nine nine."

    assert Phone.validate(%{"phone" => "+12025550199", "evidence" => punctuated}, punctuated) ==
             {:ok, %{phone: "+12025550199"}}

    assert Phone.validate(
             %{"phone" => "+12025550199", "evidence" => spoken},
             "It's " <> spoken <> "."
           ) == {:ok, %{phone: "+12025550199"}}

    assert {:error, _} =
             Phone.validate(%{"phone" => "+12025550199", "evidence" => "0199"}, "0199")

    assert {:error, _} =
             Phone.validate(%{"phone" => "+12025550199", "evidence" => spoken}, "Yes, please.")

    assert Reminders.readback?("Your cell ending in zero one eight eight?", "0188")
    refute Reminders.readback?("Your cell ending in zero one eight nine?", "0188")
    refute Reminders.readback?("Your cell ending in zero one eight eight.", "0188")
    assert Reminders.phone("(202) 555-0188") == "+12025550188"
    refute Reminders.phone("0005550188")
  end

  test "phone digits can be completed across caller replies without inventing an area code" do
    assert {:incomplete, [:phone], %{evidence: ["two zero two five five five"]}} =
             Phone.validate(
               %{"phone" => nil, "evidence" => "two zero two five five five"},
               "two zero two five five five"
             )

    result = %{
      "phone" => "+12025550199",
      "evidence" => ["two zero two five five five", "zero one nine nine"]
    }

    assert {:ok, %{phone: "+12025550199"}} =
             Phone.validate(result, "zero one nine nine", ["two zero two five five five"])

    assert {:error, :invalid_extraction} = Phone.validate(result, "zero one nine nine")

    assert {:error, :invalid_extraction} =
             Phone.validate(result, "Yes", ["two zero two five five five"])

    assert {:error, :invalid_extraction} =
             Phone.validate(
               %{"phone" => "+12025520255", "evidence" => ["20255", "20255"]},
               "20255"
             )
  end

  defp sql(db, query) do
    {:ok, st} = Exqlite.Sqlite3.prepare(db, query)
    {:ok, rows} = Exqlite.Sqlite3.fetch_all(db, st)
    Exqlite.Sqlite3.release(db, st)
    rows
  end
end
