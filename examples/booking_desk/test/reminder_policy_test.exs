defmodule BookingDesk.ReminderPolicyTest do
  use ExUnit.Case, async: true
  alias BookingDesk.ReminderPolicy

  defp snapshot(question, answer) do
    %{
      session_id: "test",
      provider_generation: 1,
      transcripts: [
        %{speaker: :user, delta: answer, arrival_order: 2},
        %{speaker: :assistant, delta: question, arrival_order: 1}
      ]
    }
  end

  test "only the exact current destination readback can authorize scheduling" do
    state = %{
      status: "verify_existing",
      destination: "+12025550188",
      patient: "p",
      original_phone: "2025550188"
    }

    opts = [reminder_judge: fn _ -> {:ok, "confirm_number"} end]

    assert {:input, %{operation: "reminder_confirm", destination: "+12025550188"}} =
             ReminderPolicy.interpret(
               snapshot(
                 "Can we text your cell ending in zero one eight eight?",
                 "Yep, that's my cell."
               ),
               state,
               opts
             )

    assert {:clarify, _} =
             ReminderPolicy.interpret(
               snapshot("Can we text your cell ending in zero one eight nine?", "Yep."),
               state,
               opts
             )

    assert {:clarify, _} =
             ReminderPolicy.interpret(
               snapshot("Would you like a text reminder?", "Yep."),
               state,
               opts
             )

    new = %{state | status: "verify_new"}

    assert {:clarify, _} =
             ReminderPolicy.interpret(
               snapshot("Your cell ending in zero one eight eight?", "Yep."),
               new,
               opts
             )

    assert {:input, _} =
             ReminderPolicy.interpret(
               snapshot("Is two zero two five five five zero one eight eight correct?", "Yep."),
               new,
               opts
             )
  end

  test "booking yes cannot stand in for reminder consent" do
    state = %{status: "offered", patient: "p", original_phone: "2025550188"}
    opts = [reminder_judge: fn _ -> {:ok, "opt_in"} end]

    assert :associate =
             ReminderPolicy.interpret(snapshot("Shall I book Thursday?", "Yes."), state, opts)

    assert {:input, %{operation: "reminder_opt_in"}} =
             ReminderPolicy.interpret(
               snapshot("Would you like a text reminder?", "Yeah."),
               state,
               opts
             )
  end

  test "structured phone extraction gets the caller binding and never authorizes scheduling" do
    state = %{status: "need_number", patient: "p", original_phone: nil}

    assert {:input, %{operation: "reminder_number", phone: "+12025550199"}} =
             ReminderPolicy.interpret(snapshot("What's your cell?", "2025550199"), state,
               reminder_judge: fn _ -> {:ok, "number"} end,
               phone_extractor: fn request ->
                 assert request.interpretation_binding.caller_cursor == 2
                 {:ok, %{phone: "+12025550199"}}
               end
             )
  end
end
