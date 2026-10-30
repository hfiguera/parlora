import Config

# Evaluated by this application, including when a release boots.
# Parlora never reads environment variables or the Keychain for credentials.
config :order_desk, :openai_api_key, System.get_env("OPENAI_API_KEY")
config :order_desk, :gemini_api_key, System.get_env("GEMINI_API_KEY")
config :order_desk, :grok_api_key, System.get_env("XAI_API_KEY")
config :order_desk, :phonic_api_key, System.get_env("PHONIC_API_KEY")

backend =
  case System.get_env("PARLORA_BACKEND", "jido") do
    "jido" -> :jido
    "sagents" -> :sagents
    "legion" -> :legion
    _invalid -> raise "PARLORA_BACKEND must be jido, sagents or legion"
  end

config :order_desk, :backend, backend

config :order_desk, :sagents, %{
  model: System.get_env("SAGENTS_MODEL", "gpt-6-luna"),
  api_key: System.get_env("SAGENTS_API_KEY"),
  reasoning_effort: "none"
}

config :order_desk, :legion, %{
  model: System.get_env("LEGION_MODEL", "gpt-6-luna"),
  api_key: System.get_env("LEGION_API_KEY"),
  reasoning_effort: "none"
}

# Legion calls generate_object/3; tuple defaults cannot carry api_key.
# This host owns ReqLLM provider credentials; the adapter never changes them.
if backend == :legion do
  config :req_llm, :openai_api_key, System.get_env("LEGION_API_KEY")
end

grok_reasoning =
  case System.get_env("GROK_REASONING_EFFORT", "high") do
    "high" -> :high
    "none" -> :none
    _invalid -> raise "GROK_REASONING_EFFORT must be high or none"
  end

config :order_desk, :grok_reasoning_effort, grok_reasoning

voice_provider =
  case System.get_env("PARLORA_PROVIDER", "openai") do
    "openai" -> :openai
    "gemini" -> :gemini
    "grok" -> :grok
    "phonic" -> :phonic
    _invalid -> raise "PARLORA_PROVIDER must be openai, gemini, grok, or phonic"
  end

config :order_desk, :voice_provider, voice_provider

config :order_desk, :typesafe_api_key, System.get_env("TYPESAFE_API_KEY")

config :order_desk, :twilio, %{
  account_sid: System.get_env("TWILIO_ACCOUNT_SID"),
  auth_token: System.get_env("TWILIO_AUTH_TOKEN"),
  phone_number: System.get_env("TWILIO_PHONE_NUMBER"),
  public_url: System.get_env("TWILIO_PUBLIC_URL"),
  port: String.to_integer(System.get_env("TWILIO_PORT", "4100")),
  review_port: String.to_integer(System.get_env("TWILIO_REVIEW_PORT", "4101"))
}

config :order_desk, :telnyx, %{
  api_key: System.get_env("TELNYX_API_KEY"),
  phone_number: System.get_env("TELNYX_PHONE_NUMBER"),
  connection_id: System.get_env("TELNYX_VOICE_API_CONNECTION_ID"),
  public_key: System.get_env("TELNYX_WEBHOOK_PUBLIC_KEY"),
  public_url: System.get_env("TELNYX_PUBLIC_URL"),
  port: String.to_integer(System.get_env("TELNYX_PORT", "4200")),
  review_port: String.to_integer(System.get_env("TELNYX_REVIEW_PORT", "4201"))
}

config :order_desk,
       :recorded_input,
       config_env() == :dev and System.get_env("ORDER_DESK_RECORDED_INPUT") == "1"

if path = System.get_env("ORDER_DESK_DATABASE"), do: config(:order_desk, :database, path)
