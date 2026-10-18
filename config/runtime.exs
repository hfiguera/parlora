import Config

{provider, variable} =
  case System.get_env("PARLORA_PROVIDER", "openai") do
    "openai" -> {Parlora.Providers.OpenAI, "OPENAI_API_KEY"}
    "gemini" -> {Parlora.Providers.Gemini, "GEMINI_API_KEY"}
    "grok" -> {Parlora.Providers.Grok, "XAI_API_KEY"}
    _invalid -> raise "PARLORA_PROVIDER must be openai, gemini, or grok"
  end

config :parlora, :example_provider, provider

if api_key = System.get_env(variable) do
  config :parlora, :example_api_key, api_key
end

if provider == Parlora.Providers.Grok do
  reasoning =
    case System.get_env("GROK_REASONING_EFFORT", "high") do
      "high" -> :high
      "none" -> :none
      _invalid -> raise "GROK_REASONING_EFFORT must be high or none"
    end

  config :parlora, :example_reasoning_effort, reasoning
end
