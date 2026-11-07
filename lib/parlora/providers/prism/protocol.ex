defmodule Parlora.Providers.Prism.Protocol do
  @moduledoc false
  alias Parlora.{AudioFormat, ContextUpdate, Error}
  alias Parlora.Provider.Capabilities

  @function "delegate_to_backend"
  @voices ~w(astra aurora brando wawona)

  def capabilities do
    %Capabilities{
      audio_formats: [%AudioFormat{}],
      full_duplex?: true,
      transcripts: [:user, :assistant],
      delegation_modes: [:client],
      context_update_kinds: [:speakable],
      input_mute?: true,
      context_acknowledgment?: true
    }
  end

  def start(options, format) do
    key = Keyword.get(options, :api_key)
    voice = Keyword.get(options, :voice, "astra")
    instructions = Keyword.get(options, :instructions, "Keep replies brief.")

    selection =
      {Keyword.get(options, :model, "prism"), Keyword.get(options, :delegation, :client)}

    cond do
      not (is_binary(key) and byte_size(key) > 0) ->
        Error.tuple(:invalid_argument, "An explicit nonempty api_key is required")

      format != %AudioFormat{} ->
        Error.tuple(:unsupported, "Prism requires mono PCM16LE/24 kHz")

      selection != {"prism", :client} ->
        Error.tuple(:unsupported, "Prism supports the prism model with client delegation")

      Keyword.get(options, :history, []) != [] ->
        Error.tuple(:unsupported, "Initial history is unsupported by the Prism adapter")

      voice not in @voices or not valid_instructions?(instructions) ->
        Error.tuple(:invalid_argument, "Invalid Prism voice or instructions")

      true ->
        {:ok, %{voice: voice, instructions: instructions <> "\n" <> delegation_instruction()}}
    end
  end

  def setup(config) do
    %{
      type: "session.update",
      session: %{
        voice: config.voice,
        instructions: config.instructions,
        input_audio_format: "pcm16",
        turn_detection: %{interrupt_response: true},
        tools: [Parlora.ProviderClient.delegation_tool(@function)]
      }
    }
  end

  def configured?(
        %{
          "model" => "prism",
          "voice" => voice,
          "input_audio_format" => "pcm16",
          "turn_detection" => %{"interrupt_response" => true},
          "prism_effective_interrupt_response" => true,
          "tools" => tools
        },
        %{voice: voice}
      )
      when is_list(tools) do
    Enum.any?(tools, fn
      %{"name" => @function} -> true
      %{"function" => %{"name" => @function}} -> true
      _other -> false
    end)
  end

  def configured?(_session, _config), do: false

  def validate(
        %ContextUpdate{kind: :speakable, provider_generation: generation} = update,
        generation
      ) do
    if is_binary(update.content) and byte_size(update.content) in 1..16_000 and
         String.valid?(update.content) and String.trim(update.content) != "" and
         Enum.count_until(String.codepoints(update.content), 4_001) <= 4_000,
       do: :ok,
       else: Error.tuple(:invalid_argument, "Prism context requires 1 to 4000 text characters")
  end

  def validate(%ContextUpdate{kind: kind}, _generation) when kind != :speakable,
    do: Error.tuple(:unsupported, "Prism supports speakable context only")

  def validate(_update, _generation),
    do: Error.tuple(:invalid_argument, "Invalid or stale Prism context update")

  def arguments(%{"name" => @function, "arguments" => encoded})
      when is_binary(encoded) and byte_size(encoded) <= 8_192 do
    case JSON.decode(encoded) do
      {:ok, %{"request" => request} = args}
      when map_size(args) == 1 and is_binary(request) and byte_size(request) in 1..4_096 ->
        {:ok, args}

      _invalid ->
        Error.tuple(:invalid_argument, "Malformed Prism tool arguments")
    end
  end

  def arguments(_event), do: Error.tuple(:invalid_argument, "Unknown Prism tool")

  def audio(pcm), do: %{type: "input_audio_buffer.append", audio: Base.encode64(pcm)}

  def result(call_id, result),
    do: %{
      type: "conversation.item.create",
      item: %{type: "function_call_output", call_id: call_id, output: JSON.encode!(result)}
    }

  def continue(parent),
    do: %{
      type: "response.create",
      response: %{metadata: %{prism_cause: "tool_continuation", prism_parent_response_id: parent}}
    }

  def nudge(text),
    do: %{
      type: "response.create",
      response: %{metadata: %{prism_cause: "proactive"}, prism_instruction: text}
    }

  def report_result(call_id),
    do: %{
      type: "response.create",
      response: %{metadata: %{prism_cause: "proactive"}, prism_call_id: call_id}
    }

  def playback_drained(token),
    do: %{type: "prism.playback.drained", drain_token: token, played_ms: 0}

  def truncate(item, played_ms),
    do: %{
      type: "conversation.item.truncate",
      item_id: item,
      content_index: 0,
      audio_end_ms: played_ms
    }

  defp valid_instructions?(text), do: is_binary(text) and String.valid?(text)

  defp delegation_instruction do
    """
    Use delegate_to_backend when the application needs to handle a caller request or correction.
    The application owns validation, authorization, and execution. Continue listening while it
    works. Never claim that calling a function completed the work. Announce verified results only.
    """
  end
end
