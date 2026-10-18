defmodule OrderDesk.Provider do
  @moduledoc "Application-owned provider selection and credentials."

  def selected do
    case Application.get_env(:order_desk, :voice_provider, :openai) do
      :gemini ->
        {Parlora.Providers.Gemini, api_key: credential()}

      :grok ->
        {Parlora.Providers.Grok,
         api_key: credential(),
         reasoning_effort: Application.get_env(:order_desk, :grok_reasoning_effort, :high)}

      :openai ->
        {Parlora.Providers.OpenAI,
         api_key: credential(),
         diagnostic_sink: Application.get_env(:order_desk, :provider_diagnostic_sink),
         command_ack_timeout_ms:
           Application.get_env(:order_desk, :provider_command_ack_timeout_ms, 30_000)}
    end
  end

  def credential do
    key =
      case Application.get_env(:order_desk, :voice_provider, :openai) do
        :gemini -> :gemini_api_key
        :grok -> :grok_api_key
        :openai -> :openai_api_key
      end

    Application.get_env(:order_desk, key)
  end

  def session_options({module, _settings}, options)
      when module in [Parlora.Providers.Gemini, Parlora.Providers.Grok] do
    defaults = module.audio_limits(Keyword.get(options, :audio_format, %Parlora.AudioFormat{}))
    provider = if module == Parlora.Providers.Gemini, do: :gemini, else: :grok

    options
    |> Keyword.update(:limits, defaults, &Keyword.merge(defaults, &1))
    |> Keyword.update(
      :context,
      %{voice_provider: provider},
      &Map.put(&1, :voice_provider, provider)
    )
  end

  def session_options(_provider, options), do: options

  def append_context(session, update) do
    case Parlora.append_context(session, update) do
      {:error, %{code: :unsupported}} when update.kind == :instruction ->
        Parlora.append_context(session, %{update | kind: :speakable})

      result ->
        result
    end
  end
end
