defmodule Parlora.Providers.Gemini.Options do
  @moduledoc false
  alias Parlora.Error

  @defaults [
    realtime_input_config: [
      automatic_activity_detection: [disabled: false, silence_duration_ms: 700],
      activity_handling: :start_of_activity_interrupts
    ],
    input_audio_transcription: [mode: :verbatim]
  ]
  @nested ~w(realtime_input_config automatic_activity_detection input_audio_transcription output_audio_transcription)a
  @base ~w(api_key api_version model instructions voice history response_timeout_ms thinking_level thinking_config)a
  @activity [
    disabled: :boolean,
    start_of_speech_sensitivity:
      {:enum, [low: "START_SENSITIVITY_LOW", high: "START_SENSITIVITY_HIGH"]},
    end_of_speech_sensitivity:
      {:enum, [low: "END_SENSITIVITY_LOW", high: "END_SENSITIVITY_HIGH"]},
    prefix_padding_ms: :duration,
    silence_duration_ms: :duration
  ]
  @realtime [
    automatic_activity_detection: {:nested, @activity},
    activity_handling:
      {:enum,
       [
         start_of_activity_interrupts: "START_OF_ACTIVITY_INTERRUPTS",
         no_interruption: "NO_INTERRUPTION"
       ]},
    turn_coverage:
      {:enum,
       [
         only_activity: "TURN_INCLUDES_ONLY_ACTIVITY",
         all_input: "TURN_INCLUDES_ALL_INPUT",
         audio_activity_and_all_video: "TURN_INCLUDES_AUDIO_ACTIVITY_AND_ALL_VIDEO"
       ]},
    interim_transcript_timestamp_enabled: :boolean
  ]
  @transcription [
    language_codes: :languages,
    custom_vocabulary: :vocabulary,
    mode: {:enum, [verbatim: "VERBATIM", smart: "SMART"]}
  ]
  @fields %{
    automatic_activity_detection: :automaticActivityDetection,
    start_of_speech_sensitivity: :startOfSpeechSensitivity,
    end_of_speech_sensitivity: :endOfSpeechSensitivity,
    prefix_padding_ms: :prefixPaddingMs,
    silence_duration_ms: :silenceDurationMs,
    activity_handling: :activityHandling,
    turn_coverage: :turnCoverage,
    interim_transcript_timestamp_enabled: :interimTranscriptTimestampEnabled,
    language_codes: :languageCodes,
    custom_vocabulary: :customVocabulary
  }

  def defaults, do: @defaults

  def resolve(options) do
    with {:ok, resolved} <- merge(@defaults, options),
         {:ok, native} <- encode_options(resolved) do
      {:ok,
       Map.put(
         native,
         :manual_activity?,
         native.realtime.automaticActivityDetection[:disabled] == true
       )}
    end
  end

  def merge(base, overrides) do
    with {:ok, _} <- encode_options(base),
         {:ok, _} <- encode_options(overrides) do
      merged = Keyword.merge(base, overrides, &merge_value/3)

      with {:ok, _} <- encode_options(merged), do: {:ok, merged}
    end
  end

  defp merge_value(:automatic_activity_detection, base, overrides) do
    if Keyword.get(overrides, :disabled) == true,
      do: overrides,
      else: Keyword.merge(base, overrides)
  end

  defp merge_value(key, base, overrides) when key in @nested,
    do: Keyword.merge(base, overrides, &merge_value/3)

  defp merge_value(_key, _base, override), do: override

  defp encode_options(options) do
    known =
      @base ++ ~w(realtime_input_config input_audio_transcription output_audio_transcription)a

    with :ok <- keys(options, known),
         {:ok, realtime} <- encode(Keyword.get(options, :realtime_input_config, []), @realtime),
         {:ok, input} <-
           encode(Keyword.get(options, :input_audio_transcription, []), @transcription),
         {:ok, output} <-
           encode(Keyword.get(options, :output_audio_transcription, []), @transcription),
         :ok <- activity_dependencies(realtime) do
      {:ok, %{realtime: realtime, input: input, output: output}}
    end
  end

  defp activity_dependencies(%{automaticActivityDetection: %{disabled: true} = detection}) do
    if map_size(detection) == 1,
      do: :ok,
      else: invalid(:automatic_activity_detection)
  end

  defp activity_dependencies(_), do: :ok

  defp encode(options, schema) do
    with :ok <- keys(options, Keyword.keys(schema)) do
      Enum.reduce_while(options, {:ok, %{}}, &encode_item(&1, &2, schema))
    end
  end

  defp encode_item({key, value}, {:ok, acc}, schema) do
    case value(value, Keyword.fetch!(schema, key)) do
      {:ok, encoded} -> {:cont, {:ok, Map.put(acc, Map.get(@fields, key, key), encoded)}}
      :error -> {:halt, invalid(key)}
      error -> {:halt, error}
    end
  end

  defp keys(options, known) do
    cond do
      not Keyword.keyword?(options) -> invalid(:options)
      length(options) != length(Enum.uniq_by(options, &elem(&1, 0))) -> invalid(:options)
      key = Enum.find(Keyword.keys(options), &(&1 not in known)) -> invalid(key)
      true -> :ok
    end
  end

  defp value(value, :boolean) when is_boolean(value), do: {:ok, value}
  defp value(_value, :boolean), do: :error

  # Local admission bounds, not claims about provider quotas.
  defp value(value, :duration) when is_integer(value) and value in 0..10_000, do: {:ok, value}
  defp value(_value, :duration), do: :error

  defp value(value, {:enum, values}) do
    case List.keyfind(values, value, 0) do
      {_, encoded} -> {:ok, encoded}
      nil -> :error
    end
  end

  defp value(value, {:nested, schema}), do: encode(value, schema)

  defp value(value, kind) when kind in [:languages, :vocabulary] do
    limit = if kind == :languages, do: 16, else: 256

    if items?(value, limit, kind) and length(Enum.uniq(value)) == length(value),
      do: {:ok, value},
      else: :error
  end

  defp items?([], _, _), do: true

  defp items?([item | rest], remaining, kind) when remaining > 0 do
    text? = is_binary(item) and byte_size(item) in 1..256 and String.valid?(item)

    valid? =
      text? and
        if(kind == :languages,
          do: Regex.match?(~r/^[a-zA-Z]{2,3}(?:-[a-zA-Z0-9]{2,8})*$/, item),
          else: String.trim(item) != ""
        )

    valid? and items?(rest, remaining - 1, kind)
  end

  defp items?(_, _, _), do: false

  defp invalid(key),
    do: Error.tuple(:invalid_argument, "Invalid or unsupported Gemini option", %{setting: key})
end
