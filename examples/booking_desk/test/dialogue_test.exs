defmodule BookingDesk.DialogueTest do
  use ExUnit.Case, async: true
  alias BookingDesk.Dialogue

  test "native backchannels preserve the complete untimed caller turn and every assistant word" do
    parts =
      [
        %{speaker: :assistant, delta: "What is your date of birth?", segment_id: "question"},
        %{speaker: :user, delta: "March ", segment_id: "caller"},
        %{
          speaker: :assistant,
          delta: "Mm-hmm. ",
          segment_id: "backchannel-1",
          overlaps_user_segment_id: "caller"
        },
        %{speaker: :user, delta: "twelfth ", segment_id: "caller"},
        %{
          speaker: :assistant,
          delta: "Okay. ",
          segment_id: "backchannel-2",
          overlaps_user_segment_id: "caller"
        },
        %{speaker: :user, delta: "nineteen ninety.", segment_id: "caller"}
      ]
      |> Enum.with_index(1)
      |> Enum.map(fn {part, index} ->
        Map.merge(part, %{provider_generation: 0, arrival_order: index})
      end)
      |> Enum.reverse()

    assert Dialogue.build(parts) == [
             %{speaker: :assistant, text: "What is your date of birth?"},
             %{speaker: :user, text: "March twelfth nineteen ninety."}
           ]

    assert Dialogue.build(parts, include_assistant_reply: true) |> Enum.map(& &1.text) ==
             [
               "What is your date of birth?",
               "March twelfth nineteen ninety.",
               "Mm-hmm. ",
               "Okay. "
             ]

    next = %{
      speaker: :user,
      delta: "Yes",
      segment_id: "next",
      arrival_order: 7,
      provider_generation: 0
    }

    assert List.last(Dialogue.build([next | parts])).text == "Yes"

    assert Dialogue.build(parts, after_cursor: 4)
           |> Enum.filter(&(&1.speaker == :user))
           |> Enum.map(& &1.text) ==
             ["March twelfth ", "nineteen ninety."]
  end

  test "an overlap from another provider generation cannot join caller turns" do
    parts =
      [
        %{speaker: :user, delta: "Yes", segment_id: "caller", provider_generation: 1},
        %{
          speaker: :assistant,
          delta: "Okay",
          segment_id: "ack",
          overlaps_user_segment_id: "caller",
          provider_generation: 0
        },
        %{speaker: :user, delta: "No", segment_id: "caller", provider_generation: 1}
      ]
      |> Enum.reverse()

    assert [%{speaker: :user, text: "Yes"}, %{speaker: :assistant}, %{speaker: :user, text: "No"}] =
             Dialogue.build(parts)
  end

  test "untimed assistant fragments join within one provider reply but never across replies" do
    parts = [
      %{speaker: :assistant, delta: "Can we text 0188?", segment_id: "second", arrival_order: 4},
      %{speaker: :assistant, delta: "0188?", segment_id: "first", arrival_order: 3},
      %{speaker: :assistant, delta: "Can we text ", segment_id: "first", arrival_order: 2},
      %{speaker: :user, delta: "Yes, a reminder please", arrival_order: 1}
    ]

    assert [
             %{speaker: :user},
             %{speaker: :assistant, text: "Can we text 0188?", first_cursor: 2},
             %{speaker: :assistant, text: "Can we text 0188?", first_cursor: 4}
           ] = Dialogue.build(parts, include_assistant_reply: true, with_cursor: true)

    assert [%{speaker: :user}] = Dialogue.build(parts)
  end

  defp build(parts) do
    parts
    |> Enum.map(fn {speaker, text, first, last, generation} ->
      %{
        speaker: speaker,
        delta: text,
        start_ms: first,
        end_ms: last,
        provider_generation: generation
      }
    end)
    |> Enum.reverse()
    |> Dialogue.build()
  end

  test "monitoring can include the assistant reply without changing caller interpretation" do
    parts = [
      %{speaker: :assistant, delta: "Is your cell ending in 4289?", arrival_order: 2},
      %{speaker: :user, delta: "Yes, a reminder please", arrival_order: 1}
    ]

    assert [%{speaker: :user}] = Dialogue.build(parts)

    assert [%{speaker: :user}, %{speaker: :assistant, text: "Is your cell ending in 4289?"}] =
             Dialogue.build(parts, include_assistant_reply: true)
  end

  test "a smaller history limit keeps the newest turns in conversational order" do
    transcripts =
      for order <- 1..13 do
        %{
          speaker: if(rem(order, 2) == 1, do: :user, else: :assistant),
          delta: "turn #{order}",
          arrival_order: order
        }
      end
      |> Enum.reverse()

    assert Dialogue.build(transcripts, limit: 6) |> Enum.map(& &1.text) ==
             Enum.map(8..13, &"turn #{&1}")

    assert Dialogue.build(transcripts) |> Enum.map(& &1.text) ==
             Enum.map(4..13, &"turn #{&1}")
  end

  test "overlapping fragments preserve both speakers' words and earlier context" do
    assert build([
             {:assistant, "What can I help with?", 0, 200, 0},
             {:user, "What should I bring to the", 1000, 2200, 0},
             {:assistant, "Please", 2400, 2600, 0},
             {:user, " appointment", 2600, 2800, 0},
             {:assistant, " bring ID.", 2600, 4000, 0},
             {:user, "Thursday instead.", 6000, 7000, 0}
           ]) == [
             %{speaker: :assistant, text: "What can I help with?"},
             %{speaker: :user, text: "What should I bring to the appointment"},
             %{speaker: :assistant, text: "Please bring ID."},
             %{speaker: :user, text: "Thursday instead."}
           ]
  end

  test "multiple interleaved fragments retain one caller question" do
    assert build([
             {:user, "What should I", 1000, 1200, 0},
             {:assistant, "Please", 1200, 1600, 0},
             {:user, " bring to the", 1400, 1600, 0},
             {:assistant, " bring", 1600, 2000, 0},
             {:user, " appointment", 1800, 2000, 0}
           ]) == [%{speaker: :user, text: "What should I bring to the appointment"}]
  end

  test "separate caller replies, questions, missing clocks and generations remain boundaries" do
    for {first, overlap, last} <- [
          # A whole assistant reply is between the caller utterances.
          {{:user, "Ten fifteen", 0, 200, 0}, {:assistant, "Shall I book that?", 400, 2000, 0},
           {:user, "Yes, please.", 2200, 2400, 0}},
          # Even a short question ending at the next caller interval is a boundary.
          {{:user, "Ten fifteen", 0, 200, 0}, {:assistant, "Book it?", 200, 400, 0},
           {:user, "No.", 400, 600, 0}},
          {{:user, "No.", 0, 200, 0}, {:assistant, "Okay", 200, 400, 0},
           {:user, "Actually, yes.", 400, 600, 0}},
          # A later interruption during a long reply is a new caller request.
          {{:user, "Thursday", 0, 200, 0}, {:assistant, "Let me check", 200, 2000, 0},
           {:user, "Friday instead", 1000, 1200, 0}},
          {{:user, "Thursday", 0, 200, 0}, {:assistant, "Okay", 200, 400, 0},
           {:user, "Friday instead", 400, 600, 1}},
          {{:user, "Thursday", nil, nil, 0}, {:assistant, "Okay", nil, nil, 0},
           {:user, "Friday instead", nil, nil, 0}}
        ] do
      assert [%{speaker: :user, text: a}, %{speaker: :assistant}, %{speaker: :user, text: b}] =
               build([first, overlap, last])

      assert a == elem(first, 1)
      assert b == elem(last, 1)
    end
  end
end
