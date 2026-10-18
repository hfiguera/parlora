defmodule Parlora.OpenAIRecoveryHistoryTest do
  use ExUnit.Case, async: true
  alias Parlora.{AudioFormat, ContextSnapshot}
  alias Parlora.Provider.History
  alias Parlora.Providers.OpenAI.{Protocol, Recovery}

  test "replacement sessions preserve the selected voice and application voice instructions" do
    for voice <- ["marin", %{id: "voice_test"}, %{"id" => "voice_test"}] do
      instructions = "A warm adult voice. Speak American English. Keep replies brief."

      assert {:ok, startup} =
               Protocol.start(
                 [api_key: "test", voice: voice, instructions: instructions],
                 %AudioFormat{}
               )

      restored = Recovery.startup(startup, %ContextSnapshot{})
      assert restored.session.audio == startup.session.audio
      assert restored.session.instructions == instructions
      assert restored.event_id != startup.event_id
      assert History.valid?(restored.session.input)
    end
  end

  test "replacement history retains caller context and verified task facts with finite UTF-8 bounds" do
    {:ok, startup} =
      Protocol.start([api_key: "test", instructions: "Application rules"], %AudioFormat{})

    snapshot = %ContextSnapshot{
      transcripts: [
        %{speaker: :user, delta: String.duplicate("é", 4_000)},
        %{speaker: :assistant, delta: "Unheard generated speech"},
        %{speaker: :user, delta: "Order 124"}
      ],
      tasks: %{
        "task" => %{
          id: "task",
          revision: 2,
          status: :completed,
          input: %{order: "124"},
          recovery_result: %{status: :completed, summary: "Saved once"}
        }
      }
    }

    restored = Recovery.startup(startup, snapshot)
    assert restored.session.instructions == "Application rules"
    history = restored.session.input
    assert History.valid?(history)
    text = Enum.map_join(history, &hd(&1["content"])["text"])
    assert byte_size(text) < 6_000
    assert String.valid?(text)
    assert text =~ "Saved once"
    refute text =~ "Unheard generated speech"
    assert Enum.all?(history, &(&1["role"] != "assistant"))
  end
end
