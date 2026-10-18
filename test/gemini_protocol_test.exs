defmodule Parlora.GeminiProtocolTest do
  use ExUnit.Case, async: true
  alias Parlora.{AudioFormat, ContextUpdate}
  alias Parlora.Providers.Gemini.{Calls, Protocol}

  test "setup selects standard Live without thinking and uses nonblocking delegation" do
    assert {:ok, %{setup: setup}} = Protocol.start([api_key: "test"], %AudioFormat{})
    assert setup.model == "models/gemini-3.8-live"
    refute Map.has_key?(setup.generationConfig, :thinkingConfig)
    assert [%{functionDeclarations: [%{behavior: "NON_BLOCKING"}]}] = setup.tools
    assert setup.inputAudioTranscription == %{}
    assert setup.outputAudioTranscription == %{}
    assert setup.realtimeInputConfig.automaticActivityDetection.disabled == false
    refute Map.has_key?(setup, :proactivity)
    assert Protocol.capabilities().context_update_kinds == [:speakable]

    assert {:error, %{code: :invalid_argument}} =
             Protocol.start([api_key: "test", thinking_level: :low], %AudioFormat{})

    assert {:error, %{code: :invalid_argument}} =
             Protocol.start([api_key: "test", thinking_config: %{}], %AudioFormat{})

    assert {:error, %{code: :unsupported}} =
             Protocol.start(
               [api_key: "test", model: "gemini-3.8-live-extended-thinking"],
               %AudioFormat{}
             )

    assert {:error, _} = Protocol.start([], %AudioFormat{})

    assert {:error, %{code: :unsupported}} =
             Protocol.start([api_key: "test", model: "other"], %AudioFormat{})
  end

  test "standard turn completion reports idle while explicit background state takes precedence" do
    assert Protocol.events(%{"serverContent" => %{"turnComplete" => true}}) ==
             [:utterance_complete, {:activity, :idle}]

    assert Protocol.events(%{
             "serverContent" => %{"turnComplete" => true, "interactionStatus" => "IN_PROGRESS"}
           }) == [:utterance_complete, {:activity, :in_progress}]

    refute {:activity, :idle} in Protocol.events(%{
             "serverContent" => %{"generationComplete" => true}
           })
  end

  test "one message preserves interruption, both captions, multiple parts, activity and usage" do
    message = %{
      "serverContent" => %{
        "interrupted" => true,
        "inputTranscription" => %{"text" => "124"},
        "outputTranscription" => %{"text" => "Checking"},
        "modelTurn" => %{
          "parts" => [
            %{"inlineData" => %{"data" => "AA=="}},
            %{"text" => "private", "thought" => true},
            %{"inlineData" => %{"data" => "AQ=="}}
          ]
        },
        "turnComplete" => true,
        "interactionStatus" => "IN_PROGRESS"
      },
      "usageMetadata" => %{"totalTokenCount" => 42}
    }

    assert [
             :interrupted,
             {:transcript, caller},
             {:transcript, assistant},
             {:audio, _},
             {:audio, _},
             :utterance_complete,
             {:activity, :in_progress},
             {:usage, _}
           ] = Protocol.events(message)

    assert caller.speaker == :user and caller.start_ms == nil and caller.end_ms == nil
    assert assistant.delta == "Checking"
    refute inspect(Protocol.events(message)) =~ "private"

    assert Protocol.events(%{"toolCallCancellation" => %{"ids" => ["a", "b"]}}) == [
             {:cancel_call, "a"},
             {:cancel_call, "b"}
           ]
  end

  test "call records reject conflicts, enforce bounds, and close clarification calls once" do
    call = %{"id" => "one", "name" => Protocol.function(), "args" => %{"request" => "order 124"}}
    assert {:new, calls} = Calls.admit(Calls.new(1), call)
    assert {:duplicate, ^calls} = Calls.admit(calls, call)

    assert {:error, %{code: :invalid_argument}} =
             Calls.admit(calls, %{call | "args" => %{"request" => "order 123"}})

    assert {:error, %{code: :backpressure}} = Calls.admit(calls, %{call | "id" => "two"})

    assert {:ok, %{toolResponse: %{functionResponses: [response]}}, calls} =
             Calls.context(calls, "one", "Which order?")

    assert response.id == "one"
    assert response.scheduling == "WHEN_IDLE"
    refute Map.has_key?(response.response, :scheduling)

    assert {:ok, %{clientContent: %{turnComplete: true}}, ^calls} =
             Calls.context(calls, "one", "Order 124 arrives Friday")

    refute Calls.pending?(calls)
  end

  test "cancelled calls cannot receive late results and repeated cancellation is inert" do
    call = %{"id" => "one", "name" => Protocol.function(), "args" => %{"request" => "order 123"}}
    {:new, calls} = Calls.admit(Calls.new(4), call)
    assert {:cancelled, calls} = Calls.cancel(calls, "one")
    assert {:unchanged, ^calls} = Calls.cancel(calls, "one")
    assert {:error, _} = Calls.context(calls, "one", "Obsolete result")
    assert {:error, _} = Calls.complete(calls, "one", %{result: "obsolete"})
    assert {:error, _} = Calls.context(calls, "unknown", "Result")
  end

  test "associated work closes silently after submission without replaying speech or business work" do
    for delivery <- [nil, :pending, :accepted, :unconfirmed, :awaiting_provider, :unknown] do
      call = %{
        "id" => "late",
        "name" => Protocol.function(),
        "args" => %{"request" => "order 124"}
      }

      {:new, calls} = Calls.admit(Calls.new(4), call)

      outcome = %{
        status: :associated,
        result_delivery: delivery,
        result: "Order 124 is out for delivery."
      }

      assert {:ok, %{toolResponse: %{functionResponses: [response]}}, done} =
               Calls.complete(calls, "late", outcome)

      assert response.id == "late"
      assert response.scheduling == "SILENT"
      assert response.response == outcome
      refute Calls.pending?(done)
      assert {:error, _} = Calls.complete(done, "late", outcome)
    end
  end

  test "a rejected result and a new result still schedule an answer" do
    for outcome <- [
          %{status: :associated, result_delivery: :rejected, result: "Retry result"},
          %{result: "New result"}
        ] do
      call = %{
        "id" => "new",
        "name" => Protocol.function(),
        "args" => %{"request" => "order 124"}
      }

      {:new, calls} = Calls.admit(Calls.new(4), call)

      {:ok, %{toolResponse: %{functionResponses: [response]}}, _} =
        Calls.complete(calls, "new", outcome)

      assert response.scheduling == "WHEN_IDLE"
    end
  end

  test "instruction updates and stale generations are rejected" do
    update = %ContextUpdate{
      id: "one",
      kind: :instruction,
      content: "Speak",
      provider_generation: 0
    }

    assert {:error, %{code: :unsupported}} = Protocol.validate_update(update, 0)

    assert {:error, %{code: :invalid_argument}} =
             Protocol.validate_update(%{update | kind: :speakable}, 1)
  end
end
