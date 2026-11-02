defmodule BookingDesk.ClinicianClarificationTest do
  use ExUnit.Case, async: true
  alias BookingDesk.ClinicianClarification, as: Clarification

  defp snapshot do
    task = %{
      id: "insurance-task",
      revision: 2,
      status: :completed,
      input: %{operation: "insurance", lookup_request: "lookup"},
      request_ids: ["insurance-request"]
    }

    snapshot = %{provider_generation: 3, tasks: %{}}

    input =
      Clarification.tag(
        %{
          lookup_request: "lookup",
          missing_fields: ["clinician"],
          booking_request: %{"date" => "2026-11-04"}
        },
        snapshot,
        task,
        ["clinician"]
      )

    put_in(snapshot.tasks, %{
      task.id => Map.put(task, :clarification, %{command_id: "doctor-question", input: input})
    })
  end

  defp pending(snapshot, insurance \\ %{confirmed: true, insurance_request: "insurance-request"}) do
    Clarification.pending(snapshot, "lookup", insurance, "2026-11-04")
  end

  test "only the current verified insurance task can carry a doctor-only replay question" do
    s = snapshot()
    assert %{question_id: "doctor-question", task_revision: 2} = pending(s)

    for changed <- [
          %{s | provider_generation: 4},
          put_in(s.tasks["insurance-task"].revision, 3),
          put_in(s.tasks["insurance-task"].status, :running),
          put_in(s.tasks["insurance-task"].input.lookup_request, "other-patient"),
          put_in(s.tasks["insurance-task"].request_ids, ["other-insurance"]),
          put_in(s.tasks["insurance-task"].clarification.input.lookup_request, "other-lookup"),
          put_in(
            s.tasks["insurance-task"].clarification.input.booking_request["date"],
            "2026-11-05"
          ),
          put_in(s.tasks["insurance-task"].clarification.input.missing_fields, [
            "clinician",
            "date"
          ]),
          put_in(s.tasks["insurance-task"].clarification.input, %{}),
          %{s | tasks: %{}}
        ] do
      assert pending(changed) == nil
    end

    assert pending(s, nil) == nil
    assert pending(s, %{confirmed: false, insurance_request: "insurance-request"}) == nil
    assert pending(s, %{confirmed: true, insurance_request: "old-insurance"}) == nil

    assert Clarification.pending(
             s,
             "another-lookup",
             %{confirmed: true, insurance_request: "insurance-request"},
             "2026-11-04"
           ) == nil
  end

  test "ordinary clarifications do not acquire a doctor replay marker" do
    input = %{missing_fields: ["date"]}

    assert Clarification.tag(input, %{provider_generation: 0}, %{id: "task", revision: 1}, [
             "date"
           ]) == input

    assert Clarification.tag(input, %{provider_generation: 0}, nil, ["clinician"]) == input
  end
end
