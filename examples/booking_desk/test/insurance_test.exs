defmodule BookingDesk.InsuranceTest do
  use ExUnit.Case, async: false
  alias BookingDesk.{Insurance, Store}

  setup do
    store = start_supervised!({Store, path: ":memory:", name: :insurance_test_store})
    input = %{operation: "lookup", name: "Jamie Rivera", dob: "1990-03-12", session: "call"}
    result = Store.execute(input, "lookup", store)
    binding = %{patient: "p_1002", lookup_request: "lookup", session: "call"}
    %{store: store, binding: binding, lookup: result}
  end

  defp review(store, binding, response, carrier, revision, id),
    do:
      Store.execute(
        Map.merge(binding, %{
          operation: "insurance",
          response: response,
          carrier: carrier,
          insurance_revision: revision
        }),
        id,
        store
      )

  test "carrier comes from a matched record and scheduling requires that call's review", c do
    assert c.lookup["facts"]["insurance"]["carrier"] == "Aetna"
    assert Store.insurance("missing", "call", c.store) == nil
    assert Store.insurance("lookup", "other-call", c.store) == nil

    availability =
      Map.merge(c.binding, %{
        operation: "availability",
        date: "2026-11-05",
        clinician: "lee",
        cursor: 3
      })

    assert Store.execute(availability, "too-early", c.store)["status"] == "failed"
    confirmed = review(c.store, c.binding, "unchanged", "Aetna", 1, "review")
    assert confirmed["status"] == "completed"
    assert confirmed["facts"]["eligibility_verified"] == false
    assert length(Store.snapshot(c.store)) == 1

    assert Store.execute(Map.put(availability, :insurance_request, "review"), "ready", c.store)[
             "status"
           ] == "completed"

    Store.execute(
      %{operation: "lookup", name: "Jamie Rivera", dob: "1990-03-12", session: "call"},
      "new-lookup",
      c.store
    )

    refute Store.insurance("new-lookup", "call", c.store).confirmed

    assert Store.execute(
             Map.merge(availability, %{insurance_request: "review", lookup_request: "new-lookup"}),
             "wrong-proof",
             c.store
           )["status"] == "failed"
  end

  test "changed insurance revokes prior proof and proposals; update requires current revision",
       c do
    review(c.store, c.binding, "unchanged", "Aetna", 1, "old-review")
    base = Map.put(c.binding, :insurance_request, "old-review")

    Store.execute(
      Map.merge(base, %{
        operation: "availability",
        date: "2026-11-05",
        clinician: "lee",
        cursor: 3
      }),
      "offers",
      c.store
    )

    Store.execute(
      Map.merge(base, %{
        operation: "propose",
        slot: "2026-11-05T10:15:00",
        clinician: "lee",
        revision: 4,
        search_cursor: 3
      }),
      "proposal",
      c.store
    )

    assert Store.readback_proposal("p_1002", "proposal", 4, c.store)
    changed = review(c.store, c.binding, "changed", "Aetna", 1, "changed")
    assert changed == review(c.store, c.binding, "changed", "Aetna", 1, "changed")
    assert Store.insurance("lookup", "call", c.store).needs_update
    refute Store.insurance("lookup", "call", c.store).confirmed
    refute Store.readback_proposal("p_1002", "proposal", 4, c.store)
    assert review(c.store, c.binding, "updated", "Cigna", 1, "stale-update")["status"] == "failed"

    assert review(c.store, c.binding, "unchanged", "Aetna", 2, "invalid-same")["status"] ==
             "failed"

    assert review(c.store, c.binding, "updated", "", 2, "blank")["status"] == "failed"

    assert review(c.store, c.binding, "updated", "Cigna", 2, "new-review")["status"] ==
             "completed"

    assert %{carrier: "Cigna", revision: 3, confirmed: true} =
             Store.insurance("lookup", "call", c.store)

    assert review(c.store, c.binding, "unchanged", "Aetna", 3, "wrong-carrier")["status"] ==
             "failed"

    assert Store.execute(
             Map.merge(c.binding, %{
               operation: "confirm",
               proposal: "proposal",
               revision: 4,
               insurance_request: "new-review"
             }),
             "obsolete-proposal",
             c.store
           )["status"] == "failed"

    assert length(Store.snapshot(c.store)) == 1
  end

  test "changed carrier persists across reopening the database without changing other patients" do
    path = Path.join(System.tmp_dir!(), "insurance-#{System.unique_integer([:positive])}.db")
    on_exit(fn -> File.rm(path) end)
    {:ok, store} = Store.start_link(path: path, name: :insurance_persistence_store)

    Store.execute(
      %{operation: "lookup", name: "Jamie Rivera", dob: "1990-03-12", session: "p"},
      "p-lookup",
      store
    )

    binding = %{patient: "p_1002", lookup_request: "p-lookup", session: "p"}
    review(store, binding, "updated", "UnitedHealthcare", 1, "updated")
    GenServer.stop(store)
    {:ok, reopened} = Store.start_link(path: path, name: :insurance_persistence_store)
    assert Store.insurance("p-lookup", "p", reopened).carrier == "UnitedHealthcare"

    Store.execute(
      %{operation: "lookup", name: "Alex Morgan", dob: "1985-07-24", session: "a"},
      "alex",
      reopened
    )

    assert Store.insurance("alex", "a", reopened).carrier == "Cigna"
    GenServer.stop(reopened)
  end

  test "structured carrier extraction is grounded in latest caller words and rejects incomplete responses" do
    caller = "I switched to Blue Cross Blue Shield."
    valid = %{"carrier" => "Blue Cross Blue Shield", "evidence" => "Blue Cross Blue Shield"}

    assert Insurance.validate(
             %{"carrier" => "Cigna", "evidence" => "I switched to Cigna."},
             "I switched to Cigna."
           ) == {:error, :invalid_extraction}

    assert Insurance.validate(valid, caller) == {:ok, %{carrier: "Blue Cross Blue Shield"}}
    assert Insurance.validate(valid, "Yep, same one.") == {:error, :invalid_extraction}

    assert Insurance.validate(Map.put(valid, "patient", "p_1002"), caller) ==
             {:error, :invalid_extraction}

    assert Insurance.validate(%{"carrier" => nil, "evidence" => nil}, "It changed.") ==
             {:incomplete, [:carrier]}

    state = %{dialogue: [], latest_user: caller}

    assert Insurance.extract(state,
             generate: fn _, _, schema, opts ->
               assert schema["additionalProperties"] == false
               assert opts[:openai_structured_output_mode] == :json_schema
               assert opts[:provider_options][:store] == false

               {:ok,
                %ReqLLM.Response{
                  id: "test",
                  model: "gpt-6-luna",
                  context: nil,
                  finish_reason: :length
                }}
             end
           ) == {:error, :unavailable}
  end

  test "replay responds only to a question about the returned carrier, never an invented insurer" do
    assert Insurance.requested?("I have Aetna on file. Is that still your insurance?", "Aetna")
    refute Insurance.requested?("I have Cigna on file. Is that still your insurance?", "Aetna")
    refute Insurance.requested?("Bring your Aetna insurance card.", "Aetna")

    for provider <- ["openai", "gemini", "grok", "phonic"] do
      prompt = BookingDesk.instructions(provider)
      refute prompt =~ "Aetna"
      refute prompt =~ "Cigna"
      assert prompt =~ "eligibility"
    end
  end
end
