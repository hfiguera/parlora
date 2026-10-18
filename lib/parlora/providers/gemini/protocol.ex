defmodule Parlora.Providers.Gemini.Protocol do
  @moduledoc false
  alias Parlora.{AudioFormat, ContextUpdate, Error}
  alias Parlora.Provider.Capabilities
  alias Parlora.Provider.History

  @model "gemini-3.8-live"
  @function "delegate_to_backend"

  def capabilities do
    %Capabilities{
      audio_formats: [%AudioFormat{}, AudioFormat.pcmu()],
      full_duplex?: true,
      transcripts: [:user, :assistant],
      delegation_modes: [:client],
      context_update_kinds: [:speakable],
      input_mute?: true,
      usage?: true
    }
  end

  def start(options, format) do
    if Keyword.get(options, :response_timeout_ms, 12_000) in 1..60_000,
      do: configure(options, format),
      else: Error.tuple(:invalid_argument, "response_timeout_ms must be between 1 and 60000")
  end

  defp configure(options, format) do
    key = Keyword.get(options, :api_key)
    version = Keyword.get(options, :api_version, :v1beta)
    instructions = Keyword.get(options, :instructions, "Keep replies brief.")
    voice = Keyword.get(options, :voice, "Puck")
    history = Keyword.get(options, :history, [])

    cond do
      not nonempty_string?(key) ->
        Error.tuple(:invalid_argument, "An explicit nonempty api_key is required")

      Keyword.get(options, :model, @model) != @model ->
        Error.tuple(:unsupported, "Only gemini-3.8-live is implemented")

      Keyword.has_key?(options, :thinking_level) or Keyword.has_key?(options, :thinking_config) ->
        Error.tuple(:invalid_argument, "gemini-3.8-live does not support thinking configuration")

      version not in [:v1beta, :v1alpha] ->
        Error.tuple(:invalid_argument, "Invalid api_version")

      not AudioFormat.supported?(format) ->
        Error.tuple(:unsupported, "Gemini requires mono PCM16LE/24 kHz or mu-law/8 kHz")

      not valid_context?(instructions, voice, history) ->
        Error.tuple(:invalid_argument, "Invalid instructions, voice, or text history")

      true ->
        {:ok, setup(instructions, voice, history)}
    end
  end

  def function, do: @function

  defp nonempty_string?(value), do: is_binary(value) and value != ""

  defp valid_context?(instructions, voice, history),
    do: is_binary(instructions) and is_binary(voice) and History.valid?(history)

  def path(version),
    do: "/ws/google.ai.generativelanguage.#{version}.GenerativeService.BidiGenerateContent"

  def audio(pcm, rate),
    do: %{
      realtimeInput: %{audio: %{mimeType: "audio/pcm;rate=#{rate}", data: Base.encode64(pcm)}}
    }

  def text(content) do
    %{
      clientContent: %{
        turns: [%{role: "user", parts: [%{text: "Application update: " <> content}]}],
        turnComplete: true
      }
    }
  end

  def tool_result(id, content, scheduling \\ "WHEN_IDLE") do
    %{
      toolResponse: %{
        functionResponses: [
          %{id: id, name: @function, response: content, scheduling: scheduling}
        ]
      }
    }
  end

  def validate_update(%ContextUpdate{} = update, generation) do
    cond do
      update.kind != :speakable ->
        Error.tuple(
          :unsupported,
          "Gemini supports speakable context, not quiet or instruction updates"
        )

      update.provider_generation != generation ->
        Error.tuple(:invalid_argument, "Stale provider generation")

      not is_binary(update.id) or update.id == "" or not is_binary(update.content) ->
        Error.tuple(:invalid_argument, "Context requires a command ID and text")

      true ->
        :ok
    end
  end

  def validate_update(_update, _generation),
    do: Error.tuple(:invalid_argument, "Expected a ContextUpdate")

  # One message can contain audio, captions, lifecycle state and usage together.
  # Preserve each observation, with interruption before any new audio.
  def events(message) when is_map(message) do
    content = Map.get(message, "serverContent", %{})

    setup_events(message) ++
      flag(content, "interrupted", :interrupted) ++
      captions(content) ++
      parts(content) ++
      calls(message) ++
      flag(content, "generationComplete", :generation_complete) ++
      utterance_boundary(content) ++
      activity(content, message) ++
      optional(message, "usageMetadata", :usage) ++
      optional(message, "sessionResumptionUpdate", :resumption) ++
      optional(message, "goAway", :go_away) ++ optional(message, "error", :error)
  end

  def events(_message), do: [{:error, :invalid_message}]

  defp setup_events(message),
    do: if(Map.has_key?(message, "setupComplete"), do: [:ready], else: [])

  defp flag(content, key, event), do: if(content[key] == true, do: [event], else: [])

  defp utterance_boundary(content),
    do:
      if(content["turnComplete"] == true or content["interrupted"] == true,
        do: [:utterance_complete],
        else: []
      )

  defp optional(message, key, type) do
    case Map.fetch(message, key) do
      {:ok, value} -> [{type, value}]
      :error -> []
    end
  end

  defp activity(content, message) do
    case content["interactionStatus"] || message["interactionStatus"] do
      "IN_PROGRESS" -> [{:activity, :in_progress}]
      "IDLE" -> [{:activity, :idle}]
      _absent -> if(content["turnComplete"] == true, do: [{:activity, :idle}], else: [])
    end
  end

  defp captions(content) do
    for {key, speaker} <- [{"inputTranscription", :user}, {"outputTranscription", :assistant}],
        %{"text" => text} <- [content[key]],
        is_binary(text) and text != "" do
      {:transcript,
       %{speaker: speaker, delta: text, start_ms: nil, end_ms: nil, timing: :unavailable}}
    end
  end

  defp parts(content) do
    for %{"inlineData" => data} <- get_in(content, ["modelTurn", "parts"]) || [],
        do: {:audio, data}
  end

  defp calls(message) do
    calls = for call <- get_in(message, ["toolCall", "functionCalls"]) || [], do: {:call, call}
    cancellations = get_in(message, ["toolCallCancellation", "ids"]) || []
    calls ++ Enum.map(cancellations, &{:cancel_call, &1})
  end

  defp setup(instructions, voice, history) do
    developers =
      for %{"role" => "developer", "content" => [%{"text" => text}]} <- history, do: text

    turns =
      for %{"role" => role, "content" => [%{"text" => text}]} <- history,
          role in ["user", "assistant"],
          do: %{role: if(role == "assistant", do: "model", else: "user"), parts: [%{text: text}]}

    config = %{
      model: "models/" <> @model,
      generationConfig: %{
        responseModalities: ["AUDIO"],
        speechConfig: %{voiceConfig: %{prebuiltVoiceConfig: %{voiceName: voice}}}
      },
      systemInstruction: %{
        parts: Enum.map([instructions | developers] ++ [delegation_instruction()], &%{text: &1})
      },
      tools: [%{functionDeclarations: [declaration()]}],
      inputAudioTranscription: %{},
      outputAudioTranscription: %{},
      realtimeInputConfig: %{
        automaticActivityDetection: %{disabled: false, silenceDurationMs: 700}
      },
      sessionResumption: %{},
      contextWindowCompression: %{slidingWindow: %{}},
      historyConfig: %{initialHistoryInClientContent: turns != []}
    }

    %{setup: config, history: turns}
  end

  defp declaration do
    %{
      name: @function,
      description: "Ask the application's backend to handle the caller's request or correction.",
      behavior: "NON_BLOCKING",
      parameters: %{
        type: "OBJECT",
        properties: %{
          request: %{type: "STRING", description: "The caller's request, without invented facts."}
        },
        required: ["request"]
      }
    }
  end

  defp delegation_instruction do
    """
    Use delegate_to_backend whenever the application instructions require backend work.
    The application owns validation, permissions, and execution. Calling the function is
    not proof work succeeded. Never invent backend facts. Continue listening while work
    runs. Application updates may arrive later, including after a clarification or an
    already-running response. Speak only the current verified result. Do not repeat an
    action just because a response is delayed.
    """
  end
end
