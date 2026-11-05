defmodule Parlora.Providers.Grok.Protocol do
  @moduledoc false
  alias Parlora.{AudioFormat, ContextUpdate, Error}
  alias Parlora.Provider.{Capabilities, History}
  alias Parlora.Providers.Grok.Settings

  @model "grok-voice-3.0"
  @function "delegate_to_backend"

  def model, do: @model
  def function, do: @function
  def path, do: "/v1/realtime?model=" <> @model

  def configured?(
        %{"model" => @model, "reasoning" => %{"effort" => effort}} = actual,
        %{reasoning: %{effort: effort}} = expected
      ),
      do: Settings.configured?(actual, expected)

  def configured?(_session, _expected_effort), do: false

  def capabilities do
    %Capabilities{
      audio_formats: [%AudioFormat{}, AudioFormat.pcmu()],
      full_duplex?: true,
      transcripts: [:user, :assistant],
      delegation_modes: [:client],
      context_update_kinds: [:speakable, :verbatim],
      input_mute?: true
    }
  end

  def start(options, format) do
    with :ok <- Settings.validate(options), do: start_validated(options, format)
  end

  defp start_validated(options, format) do
    instructions = Keyword.get(options, :instructions, "Keep replies brief.")
    voice = Keyword.get(options, :voice, "eve")
    history = Keyword.get(options, :history, [])
    reasoning = Keyword.get(options, :reasoning_effort, :high)
    key = Keyword.get(options, :api_key)

    cond do
      not valid_key?(key) ->
        Error.tuple(:invalid_argument, "An explicit nonempty api_key is required")

      not valid_selection?(options) ->
        Error.tuple(
          :unsupported,
          "Only grok-voice-3.0 with client delegation is implemented"
        )

      reasoning not in [:high, :none] ->
        Error.tuple(:invalid_argument, "reasoning_effort must be :high or :none")

      not AudioFormat.supported?(format) ->
        Error.tuple(:unsupported, "Grok requires mono PCM16LE/24 kHz or mu-law/8 kHz")

      not valid_context?(instructions, voice, history) ->
        Error.tuple(:invalid_argument, "Invalid instructions, voice, or bounded text history")

      true ->
        {:ok, configure(instructions, voice, reasoning, history, format, options)}
    end
  end

  defp valid_key?(key), do: is_binary(key) and key != ""

  defp valid_selection?(options),
    do:
      Keyword.get(options, :model, @model) == @model and
        Keyword.get(options, :delegation, :client) == :client

  defp valid_context?(instructions, voice, history),
    do: is_binary(instructions) and is_binary(voice) and History.valid?(history)

  def validate(%ContextUpdate{} = update, generation) do
    cond do
      update.kind not in [:speakable, :verbatim] ->
        Error.tuple(:unsupported, "Grok supports speakable and verbatim context only")

      update.provider_generation != generation ->
        Error.tuple(:invalid_argument, "Stale provider generation")

      not is_binary(update.content) or not is_binary(update.id) or update.id == "" ->
        Error.tuple(:invalid_argument, "Context requires text and a command ID")

      not valid_verbatim?(update) ->
        Error.tuple(
          :invalid_argument,
          "Verbatim speech requires bounded nonempty UTF-8 text and no delegation"
        )

      true ->
        :ok
    end
  end

  def validate(_update, _generation),
    do: Error.tuple(:invalid_argument, "Expected a ContextUpdate")

  defp valid_verbatim?(%ContextUpdate{kind: :verbatim} = update),
    do:
      update.delegation_id == nil and byte_size(update.content) in 1..16_384 and
        String.valid?(update.content) and String.trim(update.content) != ""

  defp valid_verbatim?(_update), do: true

  def text(content),
    do: %{
      type: "conversation.item.create",
      item: %{
        type: "message",
        role: "user",
        content: [%{type: "input_text", text: "Application update: " <> content}]
      }
    }

  def result(id, output),
    do: %{
      type: "conversation.item.create",
      item: %{type: "function_call_output", call_id: id, output: JSON.encode!(output)}
    }

  def audio(bytes), do: %{type: "input_audio_buffer.append", audio: Base.encode64(bytes)}
  def respond, do: %{type: "response.create"}
  def cancel, do: %{type: "response.cancel"}

  def verbatim(content),
    do: %{
      type: "conversation.item.create",
      item: %{
        type: "force_message",
        role: "assistant",
        interruptible: true,
        content: [%{type: "output_text", text: content}]
      }
    }

  defp configure(instructions, voice, reasoning, history, format, options) do
    developers =
      for %{"role" => "developer", "content" => [%{"text" => text}]} <- history, do: text

    history =
      for %{"role" => role} = item <- history,
          role != "developer",
          do: %{type: "conversation.item.create", item: history_item(item)}

    codec =
      if format.codec == :pcmu,
        do: %{type: "audio/pcmu"},
        else: %{type: "audio/pcm", rate: 24_000}

    %{
      history: history,
      setup: %{
        type: "session.update",
        session:
          Settings.configure(
            %{
              voice: voice,
              reasoning: %{effort: Atom.to_string(reasoning)},
              instructions:
                Enum.join([instructions | developers] ++ [delegation_instruction()], "\n"),
              turn_detection: %{type: "server_vad"},
              resumption: %{enabled: false},
              audio: %{
                input: %{format: codec, transcription: %{model: "grok-transcribe"}},
                output: %{format: codec}
              },
              tools: [
                %{
                  type: "function",
                  name: @function,
                  description:
                    "Ask the application to handle the caller's request or correction.",
                  parameters: %{
                    type: "object",
                    properties: %{request: %{type: "string"}},
                    required: ["request"],
                    additionalProperties: false
                  }
                }
              ]
            },
            options
          )
      }
    }
  end

  defp history_item(%{"role" => "assistant", "content" => [part]} = item),
    do:
      item
      |> Map.put("type", "message")
      |> Map.put("content", [Map.put(part, "type", "output_text")])

  defp history_item(item), do: Map.put(item, "type", "message")

  defp delegation_instruction do
    """
    Use delegate_to_backend whenever application instructions require backend work.
    The application owns validation, permissions, revisions and execution. Continue
    listening and answering unrelated questions while work runs. Calling a function
    does not establish success. Corrections supersede previous requests. Never repeat
    an action because a result is delayed. Announce only current verified results.
    """
  end
end
