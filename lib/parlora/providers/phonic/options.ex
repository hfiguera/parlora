defmodule Parlora.Providers.Phonic.Options do
  @moduledoc false
  alias Parlora.Error

  @defaults [
    model: "phonic-1",
    voice: "sabrina",
    instructions: "Keep replies brief.",
    tool_timeout_ms: 60_000,
    acknowledgment_timeout_ms: 5_000,
    response_timeout_ms: 15_000,
    early_delegation: false,
    zero_data_retention: false,
    enable_assistant_backchannel: true,
    assistant_backchannel_aggressiveness: 0.3,
    require_speech_before_tool_call: true,
    wait_for_speech_before_tool_call: false,
    wait_for_response: true,
    forbid_speech_after_tool_call: true,
    audio_speed: 1.05,
    vad_threshold: 0.5,
    vad_min_speech_duration_ms: 120,
    vad_min_silence_duration_ms: 600,
    min_words_to_interrupt: 1,
    background_noise: nil,
    background_noise_level: 0,
    no_input_end_conversation_sec: 600
  ]

  @base ~w(api_key model voice instructions history tool_timeout_ms acknowledgment_timeout_ms response_timeout_ms early_delegation zero_data_retention)a
  @conversation [
    enable_assistant_backchannel: :boolean,
    assistant_backchannel_aggressiveness: {:number, 0, 1},
    audio_speed: {:number, 0.5, 1.5},
    background_noise: {:enum, [nil, "office", "call-center", "coffee-shop"]},
    background_noise_level: {:number, 0, 0.25},
    vad_prebuffer_duration_ms: {:integer, 0, 2000},
    vad_min_speech_duration_ms: {:integer, 0, 1500},
    vad_min_silence_duration_ms: {:integer, 0, 1500},
    vad_threshold: {:number, 0.2, 0.8},
    min_words_to_interrupt: {:integer, 1, 10},
    boosted_keywords: :keywords,
    pronunciation_dictionary: :dictionary,
    intelligence_level: {:enum, ["standard", "high"]},
    default_language: :language,
    additional_languages: :languages,
    multilingual_mode: {:enum, ["auto", "request", "initial"]},
    generate_no_input_poke_text: :boolean,
    no_input_poke_sec: :poke_delay,
    no_input_poke_text: {:text, 1000},
    no_input_end_conversation_sec: {:integer, 30, 600}
  ]
  @tool [
    require_speech_before_tool_call: :boolean,
    wait_for_speech_before_tool_call: :boolean,
    wait_for_response: :boolean,
    forbid_speech_after_tool_call: :boolean
  ]
  @owned [
    execution_mode: "async",
    allow_tool_chaining: false
  ]

  def defaults, do: @defaults
  def get(options, key), do: Keyword.get(options, key, Keyword.fetch!(@defaults, key))

  def resolve(options) do
    if Keyword.keyword?(options) do
      with :ok <- validate_keys(options),
           resolved <- inherit(options),
           :ok <- validate_values(resolved),
           :ok <- validate_ownership(resolved),
           :ok <- validate_dependencies(resolved),
           do: {:ok, resolved}
    else
      invalid(:options, "Phonic options must be a keyword list")
    end
  end

  defp inherit(options) do
    resolved = Keyword.merge(@defaults, options)

    if Keyword.fetch!(resolved, :enable_assistant_backchannel) == false and
         not Keyword.has_key?(options, :assistant_backchannel_aggressiveness),
       do: Keyword.delete(resolved, :assistant_backchannel_aggressiveness),
       else: resolved
  end

  def conversation(options) do
    options
    |> Keyword.take(Keyword.keys(@conversation))
    |> Map.new(fn
      {:pronunciation_dictionary, entries} ->
        {:pronunciation_dictionary,
         Enum.map(entries, fn entry ->
           {word, pronunciation} = dictionary_entry(entry)
           %{word: word, pronunciation: pronunciation}
         end)}

      pair ->
        pair
    end)
  end

  def tool(options), do: Map.new(Keyword.take(options, Keyword.keys(@tool)))

  defp validate_keys(options) do
    known = @base ++ Keyword.keys(@conversation) ++ Keyword.keys(@tool) ++ Keyword.keys(@owned)
    keys = Keyword.keys(options)

    cond do
      length(keys) != length(Enum.uniq(keys)) -> invalid(:options, "Duplicate Phonic option")
      key = Enum.find(keys, &(&1 not in known)) -> invalid(key, "Unknown Phonic option")
      true -> :ok
    end
  end

  defp validate_values(options) do
    Enum.reduce_while(@conversation ++ @tool, :ok, fn {key, spec}, :ok ->
      if not Keyword.has_key?(options, key) or valid?(Keyword.fetch!(options, key), spec),
        do: {:cont, :ok},
        else: {:halt, invalid(key, "Invalid native Phonic setting")}
    end)
  end

  defp validate_ownership(options) do
    case Enum.find(@owned, fn {key, value} -> Keyword.get(options, key, value) != value end) do
      {key, _} ->
        Error.tuple(
          :unsupported,
          "Phonic requires asynchronous tools without tool chaining",
          %{setting: key}
        )

      nil ->
        :ok
    end
  end

  defp validate_dependencies(options) do
    cond do
      Keyword.get(options, :forbid_speech_after_tool_call, true) == false and
          not Keyword.fetch!(options, :wait_for_response) ->
        Error.tuple(
          :unsupported,
          "Automatic post-tool speech requires native busy response ownership",
          %{setting: :forbid_speech_after_tool_call}
        )

      Keyword.has_key?(options, :assistant_backchannel_aggressiveness) and
          not Keyword.fetch!(options, :enable_assistant_backchannel) ->
        invalid(
          :assistant_backchannel_aggressiveness,
          "Backchannel aggressiveness requires enabled backchannels"
        )

      Keyword.get(options, :multilingual_mode) == "auto" and
          Enum.count_until(Keyword.get(options, :additional_languages, []), 3) > 2 ->
        invalid(
          :additional_languages,
          "Automatic language selection supports at most two additional languages"
        )

      Keyword.get(options, :default_language, "en") in Keyword.get(
        options,
        :additional_languages,
        []
      ) ->
        invalid(:additional_languages, "Additional languages must exclude the default language")

      true ->
        :ok
    end
  end

  defp valid?(value, :boolean), do: is_boolean(value)

  defp valid?(value, {:number, low, high}),
    do: is_number(value) and value >= low and value <= high

  defp valid?(value, {:integer, low, high}),
    do: is_integer(value) and value >= low and value <= high

  defp valid?(value, {:enum, values}), do: value in values

  defp valid?(value, {:text, max}),
    do:
      is_binary(value) and byte_size(value) in 1..(max * 4) and String.valid?(value) and
        length(String.to_charlist(value)) <= max

  defp valid?(value, :language), do: is_binary(value) and Regex.match?(~r/^[a-z]{2}$/, value)

  defp valid?(nil, :poke_delay), do: true
  defp valid?(value, :poke_delay), do: valid?(value, {:integer, 1, 120})
  defp valid?(values, :keywords), do: valid_list?(values, 256, &valid?(&1, {:text, 50}))
  defp valid?(values, :languages), do: valid_list?(values, 256, &valid?(&1, :language))

  defp valid?(values, :dictionary) do
    valid_list?(values, 256, fn value ->
      case dictionary_entry(value) do
        {word, pronunciation} ->
          valid?(word, {:text, 30}) and valid?(pronunciation, {:text, 50})

        _ ->
          false
      end
    end) and unique_words?(values)
  end

  defp valid_list?(values, max, validate),
    do:
      list_items?(values, max, validate) and
        length(Enum.uniq(values)) == length(values)

  defp list_items?([], _remaining, _validate), do: true

  defp list_items?([value | rest], remaining, validate) when remaining > 0,
    do: validate.(value) and list_items?(rest, remaining - 1, validate)

  defp list_items?(_, _, _), do: false

  defp dictionary_entry(%{word: word, pronunciation: pronunciation} = entry)
       when map_size(entry) == 2,
       do: {word, pronunciation}

  defp dictionary_entry(%{"word" => word, "pronunciation" => pronunciation} = entry)
       when map_size(entry) == 2,
       do: {word, pronunciation}

  defp dictionary_entry(_), do: nil

  defp unique_words?(entries) do
    words = Enum.map(entries, fn entry -> elem(dictionary_entry(entry), 0) end)
    length(words) == length(Enum.uniq(words))
  end

  defp invalid(key, message), do: Error.tuple(:invalid_argument, message, %{setting: key})
end
