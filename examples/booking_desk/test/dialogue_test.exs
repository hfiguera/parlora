defmodule BookingDesk.DialogueTest do
  use ExUnit.Case, async: true
  alias BookingDesk.Dialogue

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
