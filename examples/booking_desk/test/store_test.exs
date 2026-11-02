defmodule BookingDesk.StoreTest do
  use ExUnit.Case, async: false
  alias BookingDesk.Store

  setup do
    store = start_supervised!({Store, path: ":memory:", name: :booking_test_store})
    %{store: store}
  end

  defp execute(input, id, store) do
    patient = Map.get(input, :patient, "p_1002")

    {name, dob} =
      if patient == "p_1003",
        do: {"Alex Morgan", "1985-07-24"},
        else: {"Jamie Rivera", "1990-03-12"}

    session = "store-test-" <> patient
    lookup = session <> "-lookup"
    Store.execute(%{operation: "lookup", name: name, dob: dob, session: session}, lookup, store)

    insurance = Store.insurance(lookup, session, store)
    review = lookup <> "-insurance"

    Store.execute(
      %{
        operation: "insurance",
        patient: patient,
        lookup_request: lookup,
        session: session,
        response: "unchanged",
        carrier: insurance.carrier,
        insurance_revision: insurance.revision
      },
      review,
      store
    )

    clinician =
      if String.ends_with?(Map.get(input, :slot, ""), "@patel"), do: "patel", else: "lee"

    Store.execute(
      Map.merge(
        %{
          patient: patient,
          lookup_request: lookup,
          session: session,
          clinician: clinician,
          insurance_request: review
        },
        input
      ),
      id,
      store
    )
  end

  defp propose(store, id, slot \\ "2026-11-05T10:15:00", extra \\ %{}) do
    execute(
      %{
        operation: "availability",
        date: String.slice(slot, 0, 10),
        patient: Map.get(extra, :patient, "p_1002"),
        cursor: 3,
        clinician:
          Map.get(
            extra,
            :clinician,
            if(String.ends_with?(slot, "@patel"), do: "patel", else: "lee")
          )
      },
      id <> "-availability",
      store
    )

    execute(
      Map.merge(
        %{operation: "propose", patient: "p_1002", slot: slot, revision: 4, search_cursor: 3},
        extra
      ),
      id,
      store
    )
  end

  defp confirm(store, proposal, id, extra \\ %{}) do
    execute(
      Map.merge(
        %{operation: "confirm", patient: "p_1002", proposal: proposal, revision: 4},
        extra
      ),
      id,
      store
    )
  end

  test "demographic mismatch and cross-session lookup proofs cannot schedule", %{store: store} do
    assert Store.execute(
             %{operation: "lookup", name: "Jamie Rivera", dob: "1990-03-13", session: "a"},
             "wrong-dob",
             store
           )["status"] == "failed"

    assert Store.identity("wrong-dob", "a", store) == nil

    Store.execute(
      %{operation: "lookup", name: "Jamie Rivera", dob: "1990-03-12", session: "a"},
      "matched",
      store
    )

    assert Store.identity("matched", "a", store) == "p_1002"
    assert Store.identity("matched", "b", store) == nil

    for input <- [
          %{operation: "availability", date: "2026-11-05", clinician: "lee"},
          %{
            operation: "availability",
            date: "2026-11-05",
            clinician: "lee",
            patient: "p_1002",
            lookup_request: "matched",
            session: "b"
          },
          %{
            operation: "availability",
            date: "2026-11-05",
            clinician: "lee",
            patient: "p_1003",
            lookup_request: "matched",
            session: "a"
          }
        ] do
      assert Store.execute(input, "rejected-#{System.unique_integer([:positive])}", store)[
               "status"
             ] == "failed"
    end
  end

  test "any-doctor results retain distinct slots and the selected doctor through booking", %{
    store: store
  } do
    result =
      execute(
        %{operation: "availability", date: "2026-11-05", clinician: "any", cursor: 3},
        "all-doctors",
        store
      )

    slots = result["facts"]["slots"]
    assert [_, _, _, _] = slots
    assert MapSet.size(MapSet.new(slots, & &1["id"])) == 4
    assert Enum.count(slots, &(&1["time"] == "10:15")) == 2

    assert execute(
             %{
               operation: "propose",
               patient: "p_1002",
               slot: "2026-11-05T10:15:00@patel",
               clinician: "lee",
               revision: 4,
               search_cursor: 3
             },
             "wrong-doctor",
             store
           )["status"] == "failed"

    proposal =
      execute(
        %{
          operation: "propose",
          patient: "p_1002",
          slot: "2026-11-05T10:15:00@patel",
          clinician: "patel",
          revision: 4,
          search_cursor: 3
        },
        "patel-proposal",
        store
      )

    assert proposal["facts"]["clinician"] == "patel"
    assert proposal["summary"] =~ "Dr. Patel"
    booked = confirm(store, "patel-proposal", "patel-booked")
    assert booked["facts"]["clinician"] == "patel"
    assert booked["summary"] =~ "Dr. Patel"
    refute booked["summary"] =~ "Dr. Lee"
  end

  test "a verified offer is scoped to the matched lookup, even for the same patient", %{
    store: store
  } do
    execute(%{operation: "availability", date: "2026-11-05", cursor: 3}, "first-offer", store)

    Store.execute(
      %{operation: "lookup", name: "Jamie Rivera", dob: "1990-03-12", session: "other-call"},
      "other-lookup",
      store
    )

    assert Store.execute(
             %{
               operation: "propose",
               patient: "p_1002",
               session: "other-call",
               lookup_request: "other-lookup",
               slot: "2026-11-05T10:15:00",
               clinician: "lee",
               revision: 4,
               search_cursor: 3
             },
             "cross-call-offer",
             store
           )["status"] == "failed"

    assert propose(store, "first-proposal")["status"] == "completed"

    assert Store.execute(
             %{
               operation: "confirm",
               patient: "p_1002",
               session: "other-call",
               lookup_request: "other-lookup",
               proposal: "first-proposal",
               revision: 4
             },
             "cross-call-confirm",
             store
           )["status"] == "failed"
  end

  test "lookup returns routing and stored insurance without repeating supplied demographics", %{
    store: store
  } do
    result =
      Store.execute(
        %{operation: "lookup", name: "Jamie Rivera", dob: "1990-03-12", session: "lookup-test"},
        "lookup",
        store
      )

    assert result["status"] == "completed"
    assert result["facts"]["patient"] == "p_1002"
    refute String.contains?(JSON.encode!(result), ["Jamie", "Rivera"])
  end

  test "a proposal alone makes no booking; confirmation is idempotent", %{store: store} do
    assert propose(store, "proposal-a")["status"] == "completed"
    assert length(Store.snapshot(store)) == 1
    first = confirm(store, "proposal-a", "booking-a")
    assert first["status"] == "completed"
    assert confirm(store, "proposal-a", "booking-a") == first
    assert confirm(store, "proposal-a", "booking-b")["status"] == "failed"
    assert length(Store.snapshot(store)) == 2
  end

  test "readback selection binds the latest completed task to its owned pending proposal", %{
    store: store
  } do
    propose(store, "proposal-a")

    task = %{
      status: :completed,
      request_ids: ["proposal-a"],
      input: %{
        operation: "propose",
        patient: "p_1002",
        revision: 4,
        cursor: 4,
        slot: "2026-11-05T10:15:00"
      }
    }

    snapshot = %{
      session_id: "store-test-p_1002",
      application_context: %{lookup_request: "store-test-p_1002-lookup"},
      tasks: %{"t" => task}
    }

    assert %{id: "proposal-a", revision: 4, clinician: "Dr. Lee"} =
             BookingDesk.Readback.current_proposal(snapshot, store)

    for changed <- [
          %{task | status: :submitted},
          %{task | request_ids: ["unknown"]},
          put_in(task, [:input, :revision], 5),
          put_in(task, [:input, :patient], "p_1003"),
          put_in(task, [:input, :slot], "2026-11-05T14:00:00")
        ] do
      assert BookingDesk.Readback.current_proposal(%{snapshot | tasks: %{"t" => changed}}, store) ==
               nil
    end

    search = %{task | input: %{operation: "availability", cursor: 5}}

    assert BookingDesk.Readback.current_proposal(
             %{snapshot | tasks: %{"t" => task, "new" => search}},
             store
           ) == nil

    assert Store.readback_proposal("p_1003", "proposal-a", 4, store) == nil
    propose(store, "proposal-b", "2026-11-05T14:00:00")
    assert BookingDesk.Readback.current_proposal(snapshot, store) == nil
    confirm(store, "proposal-b", "booking-b")
    assert Store.readback_proposal("p_1002", "proposal-b", 4, store) == nil
  end

  test "expired proposals cannot become replay approval candidates", %{store: store} do
    propose(store, "proposal-a")
    assert Store.readback_proposal("p_1002", "proposal-a", 4, store)
    :ok = Exqlite.Sqlite3.execute(:sys.get_state(store), "UPDATE proposals SET expires=0")
    assert Store.readback_proposal("p_1002", "proposal-a", 4, store) == nil
  end

  test "wrong patient, wrong revision and conflicting request cannot write", %{store: store} do
    propose(store, "proposal-a")

    assert confirm(store, "proposal-a", "wrong-patient", %{patient: "p_1003"})["status"] ==
             "failed"

    assert confirm(store, "proposal-a", "wrong-revision", %{revision: 5})["status"] == "failed"
    confirm(store, "proposal-a", "booking-a")
    assert confirm(store, "proposal-a", "booking-a", %{revision: 5})["status"] == "failed"
    assert length(Store.snapshot(store)) == 2
  end

  test "new proposal supersedes old immutable confirmation", %{store: store} do
    propose(store, "proposal-a")
    propose(store, "proposal-b", "2026-11-05T14:00:00")
    assert confirm(store, "proposal-a", "booking-a")["status"] == "failed"
    assert confirm(store, "proposal-b", "booking-b")["status"] == "completed"
  end

  test "slot conflict is rechecked inside the write transaction", %{store: store} do
    propose(store, "proposal-a")
    propose(store, "proposal-b", "2026-11-05T10:15:00", %{patient: "p_1003"})
    assert confirm(store, "proposal-a", "booking-a")["status"] == "completed"
    assert confirm(store, "proposal-b", "booking-b", %{patient: "p_1003"})["status"] == "failed"
    assert length(Store.snapshot(store)) == 2
  end

  test "failed reschedule preserves the original appointment", %{store: store} do
    propose(store, "proposal-a", "2026-11-12T10:15:00", %{
      change: "reschedule",
      appointment: "appt_existing"
    })

    assert confirm(store, "proposal-a", "booking-a")["status"] == "failed"
    assert [["appt_existing", "p_1002", _, "booked", _]] = Store.snapshot(store)
  end

  test "reschedule books replacement and cancels original atomically", %{store: store} do
    propose(store, "proposal-a", "2026-11-05T14:00:00", %{
      change: "reschedule",
      appointment: "appt_existing"
    })

    assert %{change: "reschedule"} = Store.readback_proposal("p_1002", "proposal-a", 4, store)

    assert %{change: "reschedule", clinician_id: "lee"} =
             BookingDesk.Policy.current_proposal(
               proposal_snapshot("reschedule", "proposal-a", "2026-11-05T14:00:00"),
               store
             )

    assert confirm(store, "proposal-a", "booking-a")["status"] == "completed"

    assert Enum.any?(Store.snapshot(store), fn [id, _, _, status, _] ->
             id == "appt_existing" and status == "cancelled"
           end)
  end

  test "unavailable and backend failure are distinct verified outcomes", %{store: store} do
    empty = execute(%{operation: "availability", date: "2026-11-06"}, "empty", store)
    failure = execute(%{operation: "availability", date: "2026-11-11"}, "error", store)
    assert empty["status"] == "completed" and empty["facts"]["slots"] == []
    assert failure["status"] == "failed"
  end

  test "a model-selected calendar slot without a matching returned offer is rejected", %{
    store: store
  } do
    result =
      execute(
        %{
          operation: "propose",
          patient: "p_1002",
          slot: "2026-11-05T10:15:00",
          revision: 4,
          search_cursor: 3
        },
        "unoffered",
        store
      )

    assert result["status"] == "failed"
    assert length(Store.snapshot(store)) == 1
  end

  test "cancellation requires an owned confirmed proposal", %{store: store} do
    result =
      execute(
        %{
          operation: "propose",
          patient: "p_1002",
          change: "cancel",
          slot: "",
          appointment: "appt_existing",
          revision: 4
        },
        "cancel-proposal",
        store
      )

    assert result["status"] == "completed"
    assert [[_, _, _, "booked", _]] = Store.snapshot(store)
    assert %{change: "cancel"} = Store.readback_proposal("p_1002", "cancel-proposal", 4, store)

    assert %{change: "cancel"} =
             BookingDesk.Policy.current_proposal(
               proposal_snapshot("cancel", "cancel-proposal", ""),
               store
             )

    assert confirm(store, "cancel-proposal", "cancel-write")["status"] == "completed"
    assert [[_, _, _, "cancelled", _]] = Store.snapshot(store)
  end

  test "expired proposals cannot be read back or confirmed", %{store: store} do
    propose(store, "expired-proposal")

    :ok =
      Exqlite.Sqlite3.execute(
        :sys.get_state(store),
        "UPDATE proposals SET expires=0 WHERE id='expired-proposal'"
      )

    assert Store.readback_proposal("p_1002", "expired-proposal", 4, store) == nil

    assert BookingDesk.Policy.current_proposal(
             proposal_snapshot("book", "expired-proposal", "2026-11-05T10:15:00"),
             store
           ) == nil

    assert confirm(store, "expired-proposal", "expired-write")["status"] == "failed"
    assert length(Store.snapshot(store)) == 1
  end

  defp proposal_snapshot(change, id, slot) do
    %Parlora.ContextSnapshot{
      session_id: "store-test-p_1002",
      application_context: %{lookup_request: "store-test-p_1002-lookup"},
      tasks: %{
        "t" => %{
          id: "t",
          status: :completed,
          revision: 1,
          request_ids: [id],
          input: %{
            operation: "propose",
            change: change,
            patient: "p_1002",
            lookup_request: "store-test-p_1002-lookup",
            slot: slot,
            revision: 4,
            cursor: 4
          }
        }
      }
    }
  end
end
