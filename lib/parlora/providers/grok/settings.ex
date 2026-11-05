defmodule Parlora.Providers.Grok.Settings do
  @moduledoc false
  alias Parlora.Error

  @defaults [reasoning_effort: :high, speed: 1.0, idle_timeout_ms: nil]
  @options ~w(api_key model delegation instructions voice history reasoning_effort language_hint keyterms replace speed idle_timeout_ms)a
  @languages ~w(en ar-EG ar-SA ar-AE bn zh fr de hi id it ja ko pt-BR pt-PT ru es-MX es-ES tr vi)
  @language_codes Map.new(@languages, &{String.downcase(&1), &1})

  def defaults, do: @defaults

  def validate(options) when is_list(options) do
    if Keyword.keyword?(options) and Keyword.keys(options) -- @options == [] and
         length(options) == length(Enum.uniq_by(options, &elem(&1, 0))),
       do: validate_settings(options),
       else: invalid("Grok options must be a keyword list of supported options")
  end

  def validate(_options), do: invalid("Grok options must be a keyword list")

  defp validate_settings(options) do
    cond do
      not language?(Keyword.get(options, :language_hint)) ->
        invalid("language_hint must be nil or a documented Grok language code")

      not terms?(Keyword.get(options, :keyterms, []), 0) ->
        invalid("keyterms must contain at most 100 nonempty strings of at most 50 codepoints")

      not replacements?(Keyword.get(options, :replace, %{})) ->
        invalid("replace must map nonempty UTF-8 strings within a 65536-byte JSON budget")

      not speed?(Keyword.get(options, :speed, 1.0)) ->
        invalid("speed must be a number from 0.7 to 1.5")

      not idle?(Keyword.get(options, :idle_timeout_ms)) ->
        invalid("idle_timeout_ms must be nil or a positive integer")

      true ->
        :ok
    end
  end

  def configure(session, options) do
    transcription = session.audio.input.transcription
    hint = Keyword.get(options, :language_hint)

    transcription =
      if hint,
        do:
          Map.put(
            transcription,
            :language_hint,
            Map.fetch!(@language_codes, String.downcase(hint))
          ),
        else: transcription

    transcription = optional(transcription, :keyterms, options)

    session
    |> put_in([:audio, :input, :transcription], transcription)
    |> update_in([:audio, :output], &optional(&1, :speed, options))
    |> update_in([:turn_detection], &optional(&1, :idle_timeout_ms, options))
    |> optional(:replace, options)
  end

  def configured?(actual, expected) do
    Enum.all?(
      [
        [:replace],
        [:audio, :output, :speed],
        [:audio, :input, :transcription, :language_hint],
        [:audio, :input, :transcription, :keyterms],
        [:turn_detection, :idle_timeout_ms]
      ],
      fn path ->
        case fetch_path(expected, path) do
          :error ->
            true

          {:ok, value} ->
            actual = fetch_path(actual, Enum.map(path, &Atom.to_string/1))
            actual == {:ok, value} or (value in [nil, %{}, []] and actual == :error)
        end
      end
    )
  end

  defp fetch_path(value, []), do: {:ok, value}

  defp fetch_path(value, [key | rest]) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, next} -> fetch_path(next, rest)
      :error -> :error
    end
  end

  defp fetch_path(_value, _path), do: :error

  defp optional(map, key, options) do
    case Keyword.fetch(options, key) do
      {:ok, value} -> Map.put(map, key, value)
      :error -> map
    end
  end

  defp language?(nil), do: true

  defp language?(value) when is_binary(value),
    do: text?(value, 32) and Map.has_key?(@language_codes, String.downcase(value))

  defp language?(_value), do: false

  defp terms?([], _count), do: true

  defp terms?([term | rest], count) when count < 100,
    do: text?(term, 50) and terms?(rest, count + 1)

  defp terms?(_terms, _count), do: false

  defp replacements?(value) when is_map(value) do
    Enum.all?(value, fn {key, replacement} ->
      text?(key, 16_384) and text?(replacement, 16_384)
    end) and
      byte_size(JSON.encode!(value)) <= 65_536
  end

  defp replacements?(_value), do: false

  defp text?(value, limit) when is_binary(value),
    do:
      byte_size(value) in 1..(limit * 4) and String.valid?(value) and
        length(String.codepoints(value)) <= limit and String.trim(value) != ""

  defp text?(_value, _limit), do: false

  defp speed?(value), do: is_number(value) and value >= 0.7 and value <= 1.5
  defp idle?(nil), do: true
  defp idle?(value), do: is_integer(value) and value > 0
  defp invalid(message), do: Error.tuple(:invalid_argument, message)
end
