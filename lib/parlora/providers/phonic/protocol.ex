defmodule Parlora.Providers.Phonic.Protocol do
  @moduledoc false
  alias Parlora.{AudioFormat, ContextUpdate, Error}
  alias Parlora.Provider.Capabilities
  @model "phonic-1"
  @function "delegate_to_backend"

  def model, do: @model
  def function, do: @function
  def path, do: "/v1/sts/ws"

  def capabilities do
    %Capabilities{
      audio_formats: [%AudioFormat{}, AudioFormat.pcmu()],
      full_duplex?: true,
      transcripts: [:user, :assistant],
      delegation_modes: [:client],
      context_update_kinds: [:quiet, :speakable, :instruction],
      input_mute?: true
    }
  end

  def start(options, format) do
    with :ok <- validate_selection(options, format),
         :ok <- validate_context(options),
         :ok <- validate_timeouts(options),
         :ok <- validate_flags(options) do
      {:ok,
       configure(
         options,
         format,
         Keyword.get(options, :instructions, "Keep replies brief."),
         Keyword.get(options, :voice, "sabrina"),
         Keyword.get(options, :tool_timeout_ms, 30_000)
       )}
    end
  end

  defp validate_selection(options, format) do
    cond do
      not text?(Keyword.get(options, :api_key), 1, 16_384) ->
        Error.tuple(:invalid_argument, "An explicit nonempty api_key is required")

      Keyword.get(options, :model, @model) != @model ->
        Error.tuple(:unsupported, "Only phonic-1 is implemented")

      not AudioFormat.supported?(format) ->
        Error.tuple(:unsupported, "Phonic requires mono PCM16LE/24 kHz or mu-law/8 kHz")

      Keyword.get(options, :history, []) != [] ->
        Error.tuple(:unsupported, "Phonic streaming history is not implemented")

      true ->
        :ok
    end
  end

  defp validate_context(options) do
    cond do
      not text?(Keyword.get(options, :instructions, "Keep replies brief."), 0, 999_000) ->
        Error.tuple(:invalid_argument, "Instructions must be valid UTF-8 of at most 999000 bytes")

      not text?(Keyword.get(options, :voice, "sabrina"), 1, 128) ->
        Error.tuple(:invalid_argument, "Voice must be a nonempty voice ID of at most 128 bytes")

      true ->
        :ok
    end
  end

  defp validate_timeouts(options) do
    constraints = [
      tool_timeout_ms: {30_000, 1_000, 180_000},
      response_timeout_ms: {15_000, 1, 60_000},
      acknowledgment_timeout_ms: {5_000, 1, 60_000}
    ]

    Enum.reduce_while(constraints, :ok, fn {key, {default, minimum, maximum}}, :ok ->
      value = Keyword.get(options, key, default)

      if is_integer(value) and value in minimum..maximum,
        do: {:cont, :ok},
        else:
          {:halt,
           Error.tuple(:invalid_argument, "Invalid Phonic timeout setting", %{setting: key})}
    end)
  end

  defp validate_flags(options) do
    if Enum.all?(
         [:zero_data_retention, :early_delegation],
         &is_boolean(Keyword.get(options, &1, false))
       ),
       do: :ok,
       else:
         Error.tuple(:invalid_argument, "Retention and early delegation options must be booleans")
  end

  defp text?(value, minimum, maximum),
    do: is_binary(value) and byte_size(value) in minimum..maximum and String.valid?(value)

  def validate(%ContextUpdate{} = update, generation) do
    cond do
      update.provider_generation != generation ->
        Error.tuple(:invalid_argument, "Stale provider generation")

      update.kind not in [:quiet, :speakable, :instruction] ->
        Error.tuple(:unsupported, "Unsupported Phonic context kind")

      not text?(update.id, 1, 256) or not text?(update.content, 1, 16_000) ->
        Error.tuple(:invalid_argument, "Context requires an ID and 1-16000 bytes of text")

      update.delegation_id != nil and update.kind != :speakable ->
        Error.tuple(:unsupported, "Only speakable context can resolve a delegation")

      true ->
        :ok
    end
  end

  def validate(_update, _generation),
    do: Error.tuple(:invalid_argument, "Expected a ContextUpdate")

  def audio(bytes), do: %{type: "audio_chunk", audio: Base.encode64(bytes)}
  def text(content), do: %{type: "add_system_message", system_message: content}
  def result(id, output), do: %{type: "tool_call_output", tool_call_id: id, output: output}

  def respond do
    %{
      type: "generate_reply",
      system_message:
        "Announce only current verified application results that have not already been announced. " <>
          "A caller correction supersedes obsolete results. Do not repeat backend work. " <>
          "If a clarification is pending, ask that question instead. Keep the response brief."
    }
  end

  def valid_output?(output) do
    if byte_size(JSON.encode!(output)) <= 16_000,
      do: :ok,
      else: Error.tuple(:invalid_argument, "Tool output must fit 16000 JSON-encoded bytes")
  rescue
    _exception -> Error.tuple(:invalid_argument, "Tool output must be JSON encodable")
  end

  defp configure(options, _format, instructions, voice, timeout) do
    codec = "pcm_24000"

    config = %{
      type: "config",
      model: @model,
      system_prompt: instructions <> "\n" <> delegation_instruction(),
      voice_id: voice,
      input_format: codec,
      output_format: codec,
      push_to_talk: false,
      stream_ahead_of_real_time: false,
      generate_welcome_message: false,
      no_input_end_conversation_sec: 600,
      tools: [tool(timeout, Keyword.get(options, :early_delegation, false))]
    }

    if Keyword.get(options, :zero_data_retention, false),
      do: Map.put(config, :data_retention_policy, %{zero_data_retention: true}),
      else: config
  end

  defp tool(timeout, early?) do
    %{
      type: "custom_websocket",
      execution_mode: "async",
      tool_call_output_timeout_ms: timeout,
      require_speech_before_tool_call: false,
      wait_for_speech_before_tool_call: false,
      wait_for_response: false,
      allow_tool_chaining: true,
      can_run_during_user_speech: early?,
      tool_schema: %{
        type: "function",
        function: %{
          name: @function,
          description:
            "Ask the application backend to handle the caller's request or correction.",
          strict: true,
          parameters: %{
            type: "object",
            properties: %{request: %{type: "string"}},
            required: ["request"],
            additionalProperties: false
          }
        }
      }
    }
  end

  defp delegation_instruction do
    "Use delegate_to_backend whenever application instructions require backend work. " <>
      "The application owns validation, permissions, task revisions and execution. " <>
      "Continue listening and answering unrelated questions while work runs. " <>
      "Calling a tool is not proof of success. Never invent backend facts or retry an action " <>
      "because its result is delayed. Caller corrections supersede obsolete requests. " <>
      "Announce only current verified results. Never describe generated speech as heard."
  end
end
