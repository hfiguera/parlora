defmodule Parlora.Providers.OpenAI.Protocol do
  @moduledoc false
  alias Parlora.{AudioFormat, ContextUpdate, Error, ID}
  alias Parlora.Provider.Capabilities
  alias Parlora.Provider.History

  @append_types %{quiet: "thinking", speakable: "commentary", instruction: "instructions"}

  def capabilities do
    %Capabilities{
      audio_formats: [%AudioFormat{}, AudioFormat.pcmu()],
      full_duplex?: true,
      transcripts: [:user, :assistant],
      delegation_modes: [:client],
      context_update_kinds: [:quiet, :speakable, :instruction],
      input_mute?: true,
      usage?: true,
      context_acknowledgment?: true
    }
  end

  def start(options, format) do
    key = Keyword.get(options, :api_key)
    model = Keyword.get(options, :model, "gpt-live-1")
    mode = Keyword.get(options, :delegation, :client)
    instructions = Keyword.get(options, :instructions, "Keep replies brief.")
    history = Keyword.get(options, :history, [])
    voice = Keyword.get(options, :voice, "marin")
    command_timeout = Keyword.get(options, :command_ack_timeout_ms, 30_000)

    cond do
      not nonempty_string?(key) ->
        Error.tuple(:invalid_argument, "An explicit nonempty api_key is required")

      not positive_integer?(command_timeout) ->
        Error.tuple(:invalid_argument, "command_ack_timeout_ms must be a positive integer")

      model != "gpt-live-1" or mode != :client ->
        Error.tuple(:unsupported, "Only gpt-live-1 with client delegation is implemented")

      not AudioFormat.supported?(format) ->
        Error.tuple(:unsupported, "OpenAI audio requires mono PCM16LE/24 kHz or μ-law/8 kHz")

      not is_binary(instructions) ->
        Error.tuple(:invalid_argument, "Instructions must be a string")

      not valid_voice?(voice) ->
        Error.tuple(
          :invalid_argument,
          "Voice must be a nonempty name or a map with only a nonempty id"
        )

      true ->
        start_history(history, model, instructions, voice, format)
    end
  end

  defp nonempty_string?(value), do: is_binary(value) and value != ""
  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp valid_voice?(voice) when is_map(voice) and map_size(voice) == 1,
    do: nonempty_string?(Map.get(voice, :id, Map.get(voice, "id")))

  defp valid_voice?(voice), do: nonempty_string?(voice)

  def append(%ContextUpdate{} = update, generation, delegations) do
    with :ok <- valid_update(update, generation, delegations) do
      {:ok,
       %{
         type: "session.#{Map.fetch!(@append_types, update.kind)}.append",
         event_id: update.id,
         content: update.content,
         delegation_id: update.delegation_id
       }}
    end
  end

  def append(_update, _generation, _delegations),
    do: Error.tuple(:invalid_argument, "Expected a ContextUpdate")

  def control(id, {:input_muted, flag}) when is_binary(id) and is_boolean(flag) do
    type = if flag, do: "session.input_audio.mute", else: "session.input_audio.unmute"
    {:ok, %{type: type, event_id: id}}
  end

  def control(_id, _control),
    do: Error.tuple(:unsupported, "Only microphone mute control is supported")

  def translate(%{"type" => "session.started", "session" => session}), do: {:ready, session}
  def translate(%{"type" => "session.output_audio.delta", "delta" => audio}), do: {:audio, audio}

  def translate(%{"type" => type, "delta" => delta, "start_ms" => start_ms, "end_ms" => end_ms})
      when type in ["session.input_transcript.delta", "session.output_transcript.delta"] do
    speaker = if type == "session.input_transcript.delta", do: :user, else: :assistant

    {:event, :transcript_delta,
     %{speaker: speaker, delta: delta, start_ms: start_ms, end_ms: end_ms}, nil}
  end

  def translate(%{
        "type" => "session.delegation.created",
        "delegation" => %{"id" => id, "target" => "client"},
        "offset_ms" => offset
      }) do
    {:delegation, %{id: id, target: :client, offset_ms: offset}}
  end

  def translate(%{"type" => type} = event)
      when type in [
             "session.thinking.appended",
             "session.commentary.appended",
             "session.instructions.appended"
           ] do
    {:ack, :context_acknowledged, event["client_event_id"],
     %{acceptance: :estimated_context_injection}}
  end

  def translate(%{"type" => type} = event)
      when type in ["session.input_audio.muted", "session.input_audio.unmuted"] do
    {:ack, :control_completed, event["client_event_id"],
     %{muted: type == "session.input_audio.muted"}}
  end

  def translate(%{"type" => "session.usage.updated", "usage" => usage} = event) do
    {:event, :usage_updated,
     %{seconds: usage["seconds"], final?: false, context_window: event["context_window"]}, nil}
  end

  def translate(%{"type" => "session.closed"} = event) do
    {:closed,
     %{
       finalized?: true,
       reason: event["reason"],
       session: event["session"],
       usage: %{seconds: get_in(event, ["usage", "seconds"]), final?: true}
     }}
  end

  def translate(%{"type" => "error", "error" => error}) do
    {:error, error["client_event_id"],
     Error.new(:adapter_failed, error["message"] || "Provider rejected a command", %{
       provider_code: error["code"],
       provider_type: error["type"],
       parameter: error["param"]
     })}
  end

  def translate(_event), do: :ignore

  defp start_history(history, model, instructions, voice, format) do
    if History.valid?(history) do
      {:ok,
       %{
         type: "session.start",
         event_id: ID.new(),
         session: %{
           model: model,
           delegation: %{type: "client"},
           store: false,
           instructions: instructions,
           input: history,
           audio: %{format: wire_format(format), output: %{voice: voice}}
         }
       }}
    else
      Error.tuple(
        :invalid_argument,
        "History supports at most 128 single-text-part developer, user, or assistant messages"
      )
    end
  end

  defp wire_format(format) do
    type = if format.codec == :pcmu, do: "audio/pcmu", else: "audio/pcm"
    %{type: type, rate: format.sample_rate_hz}
  end

  defp valid_update(update, generation, delegations) do
    cond do
      update.provider_generation != generation ->
        Error.tuple(:invalid_argument, "Stale provider generation")

      not Map.has_key?(@append_types, update.kind) ->
        Error.tuple(:unsupported, "Unsupported context kind")

      not is_binary(update.content) ->
        Error.tuple(:invalid_argument, "Context content must be a string")

      not is_binary(update.id) or update.id == "" ->
        Error.tuple(:invalid_argument, "Context requires a command ID")

      update.delegation_id != nil and not MapSet.member?(delegations, update.delegation_id) ->
        Error.tuple(:invalid_argument, "Unknown client delegation")

      true ->
        :ok
    end
  end
end
