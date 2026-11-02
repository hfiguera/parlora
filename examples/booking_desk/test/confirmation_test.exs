defmodule BookingDesk.ConfirmationTest do
  use ExUnit.Case, async: true
  alias BookingDesk.Confirmation

  defp current do
    %{
      request_id: "booking",
      confirmation: "BD-A4FAFA4A",
      readout: Confirmation.spoken("BD-A4FAFA4A"),
      reminder_status: "offered"
    }
  end

  defp snapshot(text) do
    task = %{id: "task", revision: 1, request_ids: ["booking"]}

    %{
      provider_generation: 0,
      session_id: "test",
      tasks: %{"task" => task},
      transcripts: [
        %{speaker: :assistant, delta: text, arrival_order: 21, provider_generation: 0},
        %{speaker: :user, delta: "Is it booked yet?", arrival_order: 20}
      ]
    }
  end

  defp correction(s, current \\ current()),
    do: Confirmation.correction(s, current, s.tasks["task"], 20)

  test "the repeated FA pair is never collapsed in the generated character readout" do
    spoken = Confirmation.spoken("BD-A4FAFA4A")

    assert String.split(spoken, ", ") == [
             "B as in Bravo",
             "D as in Delta",
             "dash",
             "A as in Alpha",
             "four",
             "F as in Foxtrot",
             "A as in Alpha",
             "F as in Foxtrot",
             "A as in Alpha",
             "four",
             "A as in Alpha"
           ]

    assert Confirmation.complete?(spoken, "BD-A4FAFA4A")
    refute Confirmation.complete?("B as in boy, D as in delta, A four F A four A.", "BD-A4FAFA4A")
    refute Confirmation.complete?("BD-A4FA4A", "BD-A4FAFA4A")

    for code <- ["BD-00000000", "BD-FFFFFFFF", "BD-01234567", "BD-89ABCDEF"] do
      assert Confirmation.complete?(Confirmation.spoken(code), code)
    end

    assert Confirmation.spoken(nil) == nil
    assert Confirmation.spoken("BD-invalid") == nil
  end

  test "incomplete or wrong code announcements request a full verified correction" do
    for text <- [
          "Your confirmation number is B as in boy, D as in delta, A four F A four A. Would you like a text reminder?",
          "Your confirmation number is BD-A4FAFA4B.",
          "You're booked. Would you like a text reminder?"
        ] do
      s = snapshot(text)
      assert {message, scope} = correction(s)
      assert Confirmation.complete?(message, "BD-A4FAFA4A")
      assert message =~ "Would you like a text reminder"
      assert scope.confirmation_readback.request_id == "booking"
      assert scope.confirmation_readback.after_cursor == 21
      assert correction(put_in(s.tasks["task"][:clarification], %{input: scope})) == nil
    end
  end

  test "partial captions and correct announcements are not repaired" do
    for text <- [
          "Your confirmation number is B D A four F A",
          "One moment while I check.",
          "Your confirmation number is " <> Confirmation.spoken("BD-A4FAFA4A") <> "."
        ] do
      assert correction(snapshot(text)) == nil
    end

    assert correction(snapshot("Confirmation BD-A4FA4A."), nil) == nil
    assert correction(%{snapshot("Confirmation BD-A4FA4A.") | provider_generation: 1}) == nil
  end

  test "a later booking acknowledgment does not repeat an already correct code" do
    s = snapshot("Your appointment remains booked.")

    s = %{
      s
      | transcripts:
          s.transcripts ++
            [
              %{
                speaker: :assistant,
                delta: "Confirmation " <> Confirmation.spoken("BD-A4FAFA4A") <> ".",
                arrival_order: 19
              }
            ]
    }

    assert correction(s) == nil
  end

  test "receipt, task and provider revisions bind the caption boundary" do
    s = snapshot("Confirmation BD-A4FA4A.")
    {_, input} = correction(s)

    for input <- [
          put_in(input.confirmation_readback.request_id, "old"),
          put_in(input.confirmation_readback.task_revision, 2),
          put_in(input.confirmation_readback.provider_generation, 1)
        ] do
      assert {_, _} = correction(put_in(s.tasks["task"][:clarification], %{input: input}))
    end
  end

  test "corrections are bounded and never restart a completed reminder offer" do
    s = snapshot("Confirmation BD-A4FA4A.")
    current = %{current() | reminder_status: "scheduled"}
    {message, input} = correction(s, current)
    refute message =~ "Would you like"
    s = put_in(s.tasks["task"][:clarification], %{input: input})
    s = %{s | transcripts: [%{hd(s.transcripts) | arrival_order: 22} | s.transcripts]}
    assert {_, input} = correction(s, current)
    s = put_in(s.tasks["task"][:clarification], %{input: input})
    s = %{s | transcripts: [%{hd(s.transcripts) | arrival_order: 23} | s.transcripts]}
    assert correction(s, current) == nil
  end
end
