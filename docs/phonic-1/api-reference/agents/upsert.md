> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Upsert

PUT https://api.phonic.ai/v1/agents/upsert
Content-Type: application/json

Upserts an agent by name. If an agent with the same name already exists, it will be updated. Otherwise, it will be created.

Reference: https://docs.phonic.ai/api-reference/agents/upsert

## Authentication

- `Authorization` header (bearer token, required) — Bearer authentication header of the form `Bearer <PHONIC_API_KEY>`. Manage your API keys [here](https://phonic.co/api-keys).

## Request

### Query parameters

- `project` (string, optional, default: main) — The name of the project containing the agent.

### Body (application/json)

This endpoint expects an UpsertAgentRequest.

- `name` (string, required) — The name of the agent. Can only contain lowercase letters, numbers and hyphens. Must be unique within the project.
- `additional_languages` (list of enum, optional, default: []) — Array of additional ISO 639-1 language codes that the agent should be able to recognize and speak. Should not include `default_language`. When `multilingual_mode` is `"auto"`, a maximum of 2 additional languages is allowed.
  - Allowed values: `ar`, `az`, `bg`, `bn`, `cs`, `da`, `de`, `el`, `en`, `es`, `fa`, `fi`, `fil`, `fr`, `gu`, `he`, `hi`, `hu`, `id`, `it`, `ja`, `ka`, `km`, `kn`, `ko`, `lt`, `lv`, `ml`, `mr`, `ms`, `ne`, `nl`, `no`, `pa`, `pl`, `pt`, `ro`, `ru`, `si`, `sk`, `sq`, `sv`, `sw`, `ta`, `te`, `th`, `tr`, `uk`, `ur`, `vi`, `yue`, `zh`
- `additional_voice_ids` (list of string, optional, default: []) — Additional voice IDs that, together with `voice_id`, form the agent's voice set. Each conversation is assigned one voice from the set, chosen at random with equal probability. Must not include `voice_id` and must not contain duplicates.
- `assistant_backchannel_aggressiveness` (double, optional, default: 0.1) — How aggressively the assistant produces backchannel responses. Only relevant when `enable_assistant_backchannel` is `true`.
- `audio_format` (enum, optional, default: pcm_44100) — The audio format of the agent.
  - Allowed values: `pcm_44100`, `pcm_24000`, `pcm_16000`, `pcm_8000`, `mulaw_8000`
- `audio_speed` (double, optional, default: 1.2) — The audio speed of the agent.
- `background_noise` (enum, optional) — The background noise type. Can be "office", "call-center", "coffee-shop", or null.
  - Allowed values: `office`, `call-center`, `coffee-shop`
- `background_noise_level` (double, optional, default: 0) — The background noise level of the agent.
- `boosted_keywords` (list of string, optional) — These words, or short phrases, will be more accurately recognized by the agent.
- `built_in_tool_configs` (BuiltInToolConfigs, optional) — Configuration overrides for built-in tools, keyed by built-in tool ID. Built-in tools not listed here use their default configuration.
- `configuration_endpoint` (CreateAgentRequestConfigurationEndpoint, optional, nullable) — When not `null`, at the beginning of the conversation the agent will make a POST request to this endpoint to get configuration options.
- `custom_phone_numbers` (list of string, optional, default: []) — Array of custom phone numbers in E.164 format (e.g., ["+1234567890", "+0987654321"]). The agent will be able to receive phone calls on any of these numbers. Required when `phone_number` is set to `"custom"`. All phone numbers must be unique.
- `data_retention_policy` (DataRetentionPolicy, optional) — Controls how long transcripts and audio recordings are retained before deletion.
- `default_language` (enum, optional) — ISO 639-1 language code that sets the agent's default language to recognize and speak. Welcome message and no input poke text should be in this language.
  - Allowed values: `ar`, `az`, `bg`, `bn`, `cs`, `da`, `de`, `el`, `en`, `es`, `fa`, `fi`, `fil`, `fr`, `gu`, `he`, `hi`, `hu`, `id`, `it`, `ja`, `ka`, `km`, `kn`, `ko`, `lt`, `lv`, `ml`, `mr`, `ms`, `ne`, `nl`, `no`, `pa`, `pl`, `pt`, `ro`, `ru`, `si`, `sk`, `sq`, `sv`, `sw`, `ta`, `te`, `th`, `tr`, `uk`, `ur`, `vi`, `yue`, `zh`
- `enable_assistant_backchannel` (boolean, optional, default: false) — When `true`, the assistant will produce backchannel responses (e.g. "mm-hmm") while the user is speaking.
- `enable_redaction` (boolean, optional, default: false) — When `true`, PII and PHI are redacted from text transcripts (e.g. replaced with tags like `[PHONE]`) and bleeped from audio recordings after the conversation ends.
- `enable_watermarking` (boolean, optional, default: false) — When `true`, an inaudible watermark is embedded in the audio the agent generates.
- `external_storage_policy` (string, optional, nullable) — Name of an external storage policy in the same project that conversation artifacts are delivered to. Requires zero data retention and cannot be combined with `enable_redaction`.
- `generate_no_input_poke_text` (boolean, optional, default: false) — Whether to have the no-input poke text be generated by AI.
- `generate_welcome_message` (boolean, optional, default: false) — When `true`, the welcome message will be automatically generated and the `welcome_message` field will be ignored.
- `inbound_rollout` (double, optional, default: 1) — Float between 0.0 and 1.0 representing the percentage of inbound calls handled by Agent. Defaults to `1.0`. Requires `phone_number` to be set when less than 1.0.
- `inbound_rollout_forward_phone_number` (string, optional, nullable) — E.164 formatted phone number where non-agent calls will be forwarded. Required when `inbound_rollout < 1.0`, must be `null` when `inbound_rollout = 1.0`. Defaults to `null`.
- `intelligence_level` (enum, optional, default: standard) — The intelligence level of the agent. `high` uses a more capable model for more complex reasoning, while `standard` is optimized for lower latency.
  - Allowed values: `standard`, `high`
- `is_welcome_message_interruptible` (boolean, optional, default: true) — When `false`, the welcome message will not be interruptible by the user.
- `listen_only_inbound_enabled` (boolean, optional, default: false) — Play an uninterruptible welcome message on incoming calls, then transcribe the caller without responding. Silence timeout and call duration limits still apply.
- `listen_only_inbound_message` (string, optional, nullable) — Welcome message for listen-only incoming calls. Can contain template variables like `{{customer_name}}`. Must be nonempty when `listen_only_inbound_enabled` is `true`. Replaces `welcome_message` for these calls, regardless of `generate_welcome_message`.
- `mcp_server_ids` (list of string, optional, default: []) — Array of MCP server IDs to make available to the agent.
- `min_words_to_interrupt` (integer, optional, default: 1) — Minimum number of words required to interrupt the assistant.
- `model` (CreateAgentRequestModel, optional) — The Phonic speech-to-speech model to generate with. Omit it to use the current default model.
- `multilingual_mode` (enum, optional, default: request) — If `"auto"`, each user audio is automatically identified for the language to respond in. If `"request"`, user must request to change language (recommended). If `"initial"` the first turn user audio determines the language for the rest of the conversation.
  - Allowed values: `auto`, `request`, `initial`
- `no_input_end_conversation_sec` (integer, optional, default: 180) — Seconds of silence before ending the conversation.
- `no_input_poke_sec` (integer, optional, nullable) — Number of seconds of silence before sending a poke message. `null` disables the poke message.
- `no_input_poke_text` (string, optional, default: Are you still there?) — The message to send after the specified silence. Ignored when generate_no_input_poke_text is true.
- `observability_integrations` (list of enum, optional, default: []) — Names of observability integrations to enable for the agent. Each must be one of the supported providers.
  - Allowed values: `braintrust`
- `outbound_number_pool` (OutboundNumberPool, optional, nullable) — Pool of phone numbers used for outbound calls. Set to `null` to remove the pool.
- `phone_number` (enum, optional, nullable) — When set to `null`, the agent will not be associated with a phone number. When set to `"assign-automatically"`, the agent will be assigned a random phone number. When set to `"custom"`, you must provide `custom_phone_numbers`.
  - Allowed values: `assign-automatically`, `custom`
- `procedure_ids` (list of string, optional) — Array of procedure IDs associated with the agent.
- `pronunciation_dictionary` (list of CreateAgentRequestPronunciationDictionaryItems, optional) — Array of `{ word, pronunciation }` entries. Words must be unique.
- `push_to_talk` (boolean, optional, default: false) — Push to talk mode. User must send mute/unmute messages to turn on/off listening to audio. Defaults to false.
- `slug` (string, optional) — URL-friendly agent slug. Can only contain lowercase letters, numbers and hyphens. Must be unique within the project.
- `system_prompt` (string, optional, default: Today's date is {{system_date}} {{system_year}}. The day of week is {{system_weekday}}. The current time is {{system_time}}. The timezone for the current conversation is {{system_conversation_timezone}}. Use it only for date/time calculations. Do not infer location from it.) — Instructions for the conversation. Can contain template variables like `{{subject}}`.
- `tasks` (list of Task, optional) — Array of task objects with `name` and `description` fields.
- `template_variables` (map from string to CreateAgentRequestTemplateVariables, optional) — Variables that can be used in the welcome message and the system prompt.
- `timezone` (string, optional) — The timezone of the agent. Used to format system variables like `{{system_time}}`.
- `tools` (list of CreateAgentRequestToolsItems, optional) — Array of built-in or custom tool names to use.
- `vad_min_silence_duration_ms` (integer, optional, default: 800) — Minimum silence duration for voice activity detection in milliseconds.
- `vad_min_speech_duration_ms` (integer, optional, default: 50) — Minimum speech duration for voice activity detection in milliseconds.
- `vad_prebuffer_duration_ms` (integer, optional, default: 500) — Voice activity detection prebuffer duration in milliseconds.
- `vad_threshold` (double, optional, default: 0.38) — Voice activity detection threshold.
- `voice_id` (string, optional, default: grant) — The voice ID to use.
- `websocket_timeout_sec` (integer, optional, default: 60) — Number of seconds of inactivity before the conversation WebSocket is closed.
- `welcome_message` (string, optional, nullable) — Message to play when the conversation starts. Can contain template variables like `{{customer_name}}`. Ignored when `generate_welcome_message` is `true`.
- `custom_phone_number` (string, optional, nullable, deprecated) — The custom phone number to use for the agent in E.164 format (e.g., +1234567890). This field is deprecated. Use `custom_phone_numbers` instead.
- `languages` (list of enum, optional, default: ["en"], deprecated) — Array of ISO 639-1 language codes that the agent should be able to recognize. This field is deprecated. Use `default_language` and `additional_languages` instead.
  - Allowed values: `ar`, `az`, `bg`, `bn`, `cs`, `da`, `de`, `el`, `en`, `es`, `fa`, `fi`, `fil`, `fr`, `gu`, `he`, `hi`, `hu`, `id`, `it`, `ja`, `ka`, `km`, `kn`, `ko`, `lt`, `lv`, `ml`, `mr`, `ms`, `ne`, `nl`, `no`, `pa`, `pl`, `pt`, `ro`, `ru`, `si`, `sk`, `sq`, `sv`, `sw`, `ta`, `te`, `th`, `tr`, `uk`, `ur`, `vi`, `yue`, `zh`
- `phonic_model` (CreateAgentRequestPhonicModel, optional, deprecated) — The Phonic speech-to-speech model to generate with. This field is deprecated. Use `model` instead.

## Response

### 200

Success response

- `agent` (Agent, required)
- `inserted` (boolean, required) — Whether the agent was inserted.
- `updated` (boolean, required) — Whether the agent was updated.

## Errors

### 400 Bad Request Error

Invalid parameters

- `Error`
  - BasicError: BasicError
  - ValidationError: ValidationError

### 404 Not Found Error

Project not found

- `error` (BasicErrorError, optional)

### 409 Conflict Error

Agent is disabled

- `error` (BasicErrorError, optional)

## Types

### BuiltInToolConfigs

- BuiltInToolConfig: BuiltInToolConfig
- WebSearchToolConfig: WebSearchToolConfig
- ChooseNotToRespondToolConfig: ChooseNotToRespondToolConfig

### CreateAgentRequestConfigurationEndpoint

When not `null`, at the beginning of the conversation the agent will make a POST request to this endpoint to get configuration options.

- `url` (string, required) — URL to call. Must be a publicly routable HTTPS URL without embedded credentials.
- `headers` (map from string to string, optional) — Object of key-value pairs.
- `timeout_ms` (integer, optional, default: 3000) — Timeout in milliseconds for the endpoint call.

### DataRetentionPolicy

Controls how long transcripts and audio recordings are retained before deletion. When `zero_data_retention` is `true`, nothing is retained and `transcripts`/`audio_recordings` are omitted.

- DataRetentionPolicy0
- DataRetentionPolicy1

### CreateAgentRequestModel

The Phonic speech-to-speech model to generate with. Omit it to use the current default model.

- enum
  - Allowed values: `phonic-0.5`, `phonic-1`
- string

### OutboundNumberPool

Pool of phone numbers used for outbound calls.

- `active` (list of string, required) — E.164 formatted phone numbers available for outbound calls.
- `blocked` (list of string, required) — E.164 formatted phone numbers that are blocked from being used.

### CreateAgentRequestPronunciationDictionaryItems

- `word` (string, required)
- `pronunciation` (string, required)

### Task

- `name` (string, required) — The name of the task.
- `description` (string, required) — The description of the task.

### CreateAgentRequestTemplateVariables

- `default_value` (string, required)
- `is_boosted_keyword` (boolean, optional)

### CreateAgentRequestToolsItems

- enum
  - Allowed values: `keypad_input`, `natural_conversation_ending`, `choose_not_to_respond`, `web_search`
- string

### CreateAgentRequestPhonicModel

The Phonic speech-to-speech model to generate with. This field is deprecated. Use `model` instead.

- enum
  - Allowed values: `phonic-0.5`, `phonic-1`
- string

### Agent

- `id` (string, required) — The ID of the agent.
- `name` (string, required) — The name of the agent.
- `phone_numbers` (list of string, required) — Array of phone numbers that the agent uses to accept phone calls.
- `project` (AgentProject, required) — The project the agent belongs to.
- `timezone` (string, required) — The timezone of the agent. Used to format system variables like `{{system_time}}`.
- `voice_id` (string, required) — The voice ID of the agent.
- `additional_voice_ids` (list of string, required) — Additional voice IDs that, together with `voice_id`, form the agent's voice set. Each conversation is assigned one voice from the set, chosen at random with equal probability.
- `audio_format` (enum, required) — The audio format of the agent. If the agent has a phone number, the audio format will be `mulaw_8000`.
  - Allowed values: `pcm_44100`, `pcm_24000`, `pcm_16000`, `pcm_8000`, `mulaw_8000`
- `audio_speed` (double, required) — The audio speed of the agent. Must be a multiple of 0.1.
- `background_noise_level` (double, required) — The background noise level of the agent. Must be between 0 and 1.
- `background_noise` (enum, required) — The background noise type. Can be "office", "call-center", "coffee-shop", or null.
  - Allowed values: `office`, `call-center`, `coffee-shop`
- `generate_welcome_message` (boolean, required) — When `true`, the welcome message will be automatically generated and the `welcome_message` field will be ignored.
- `is_welcome_message_interruptible` (boolean, required) — When `false`, the welcome message will not be interruptible by the user.
- `listen_only_inbound_enabled` (boolean, required) — Play an uninterruptible welcome message on incoming calls, then transcribe the caller without responding. Silence timeout and call duration limits still apply.
- `listen_only_inbound_message` (string, required, nullable) — Welcome message for listen-only incoming calls. Can contain template variables like `{{customer_name}}`. Must be nonempty when `listen_only_inbound_enabled` is `true`. Replaces `welcome_message` for these calls, regardless of `generate_welcome_message`.
- `welcome_message` (string, required, nullable) — Message to play when the conversation starts. Ignored when `generate_welcome_message` is `true`.
- `system_prompt` (string, required) — Instructions for the conversation.
- `template_variables` (map from string to AgentTemplateVariables, required) — Template variables that the agent can use in the welcome message and the system prompt.
- `tools` (list of AgentToolsItems, required) — List of tools available to the agent.
- `built_in_tool_configs` (BuiltInToolConfigs, required) — Configuration overrides for built-in tools, keyed by built-in tool ID.
- `tasks` (list of Task, required) — Tasks for the agent to complete during the conversation.
- `generate_no_input_poke_text` (boolean, required, default: false) — Whether to have the no-input poke text be generated by AI.
- `no_input_poke_sec` (integer, required, nullable) — Number of seconds of silence before sending a poke message. `null` disables the poke message.
- `no_input_poke_text` (string, required) — The message to send after the specified silence. Ignored when generate_no_input_poke_text is true.
- `no_input_end_conversation_sec` (integer, required) — Seconds of silence before ending the conversation.
- `default_language` (enum, required) — ISO 639-1 language code that sets the agent's default language to recognize and speak. Welcome message and no input poke text should be in this language.
  - Allowed values: `ar`, `az`, `bg`, `bn`, `cs`, `da`, `de`, `el`, `en`, `es`, `fa`, `fi`, `fil`, `fr`, `gu`, `he`, `hi`, `hu`, `id`, `it`, `ja`, `ka`, `km`, `kn`, `ko`, `lt`, `lv`, `ml`, `mr`, `ms`, `ne`, `nl`, `no`, `pa`, `pl`, `pt`, `ro`, `ru`, `si`, `sk`, `sq`, `sv`, `sw`, `ta`, `te`, `th`, `tr`, `uk`, `ur`, `vi`, `yue`, `zh`
- `additional_languages` (list of enum, required) — Array of additional ISO 639-1 language codes that the agent should be able to recognize and speak. Should not include `default_language`. When `multilingual_mode` is `"auto"`, a maximum of 2 additional languages is allowed.
  - Allowed values: `ar`, `az`, `bg`, `bn`, `cs`, `da`, `de`, `el`, `en`, `es`, `fa`, `fi`, `fil`, `fr`, `gu`, `he`, `hi`, `hu`, `id`, `it`, `ja`, `ka`, `km`, `kn`, `ko`, `lt`, `lv`, `ml`, `mr`, `ms`, `ne`, `nl`, `no`, `pa`, `pl`, `pt`, `ro`, `ru`, `si`, `sk`, `sq`, `sv`, `sw`, `ta`, `te`, `th`, `tr`, `uk`, `ur`, `vi`, `yue`, `zh`
- `multilingual_mode` (enum, required, default: request) — If `"auto"`, each user audio is automatically identified for the language to respond in. If `"request"`, user must request to change language (recommended). If `"initial"` the first turn user audio determines the language for the rest of the conversation.
  - Allowed values: `auto`, `request`, `initial`
- `push_to_talk` (boolean, required, default: false) — Push to talk mode. User must send mute/unmute messages to turn on/off listening to audio. Defaults to false.
- `intelligence_level` (enum, required, default: standard) — The intelligence level of the agent. `high` uses a more capable model for more complex reasoning, while `standard` is optimized for lower latency.
  - Allowed values: `standard`, `high`
- `model` (AgentModel, required) — The Phonic speech-to-speech model to generate with. Omit it to use the current default model.
- `boosted_keywords` (list of string, required) — These words, or short phrases, will be more accurately recognized by the agent.
- `pronunciation_dictionary` (list of AgentPronunciationDictionaryItems, required) — Array of `{ word, pronunciation }` entries. Words must be unique.
- `min_words_to_interrupt` (integer, required, default: 1) — Minimum number of words required to interrupt the assistant.
- `configuration_endpoint` (AgentConfigurationEndpoint, required, nullable) — When not `null`, the agent will call this endpoint to get configuration options.
- `is_disabled` (boolean, required) — When `true`, the agent is disabled. A disabled agent cannot start conversations or be updated, except to release its phone numbers.
- `phone_number` (string, required, nullable, deprecated) — The phone number that the agent uses to accept calls. `null` if the agent is not associated with a phone number, in which can the agent can be used via WebSockets. This field is deprecated. Use `phone_numbers` instead.
- `websocket_timeout_sec` (integer, optional, default: 60) — Number of seconds of inactivity before the conversation WebSocket is closed.
- `observability_integrations` (list of enum, optional) — Names of observability integrations enabled for the agent. Each must be one of the supported providers.
  - Allowed values: `braintrust`
- `external_storage_policy` (string, optional, nullable) — Name of the external storage policy that conversation artifacts are delivered to. `null` when the agent doesn't deliver artifacts to external storage.
- `inbound_rollout` (double, optional) — Float between 0.0 and 1.0 representing the percentage of inbound calls handled by Agent. Requires `phone_number` to be set when less than 1.0.
- `inbound_rollout_forward_phone_number` (string, optional, nullable) — E.164 formatted phone number where non-agent calls will be forwarded. Required when `inbound_rollout < 1.0`, must be `null` when `inbound_rollout = 1.0`.
- `vad_prebuffer_duration_ms` (integer, optional, default: 500) — Voice activity detection prebuffer duration in milliseconds.
- `vad_min_speech_duration_ms` (integer, optional, default: 50) — Minimum speech duration for voice activity detection in milliseconds.
- `vad_min_silence_duration_ms` (integer, optional, default: 800) — Minimum silence duration for voice activity detection in milliseconds.
- `vad_threshold` (double, optional, default: 0.38) — Voice activity detection threshold.
- `enable_redaction` (boolean, optional, default: false) — When `true`, PII and PHI are redacted from text transcripts (e.g. replaced with tags like `[PHONE]`) and bleeped from audio recordings after the conversation ends.
- `enable_watermarking` (boolean, optional, default: false) — When `true`, an inaudible watermark is embedded in the audio the agent generates.
- `slug` (string, optional) — The URL-friendly slug of the agent.
- `enable_assistant_backchannel` (boolean, optional, default: false) — When `true`, the assistant emits backchannel cues (e.g. "mm-hmm") while the user is speaking.
- `assistant_backchannel_aggressiveness` (double, optional, default: 0.1) — How aggressively the assistant backchannels, from 0 to 1.
- `integrations` (list of AgentIntegration, optional) — Third-party integrations enabled for the agent.
- `data_retention_policy` (DataRetentionPolicy, optional) — Controls how long transcripts and audio recordings are retained before deletion. When `zero_data_retention` is `true`, nothing is retained and `transcripts`/`audio_recordings` are omitted.
- `languages` (list of enum, optional, default: ["en"], deprecated) — Array of ISO 639-1 language codes that the agent should be able to recognize. This field is deprecated. Use `default_language` and `additional_languages` instead.
  - Allowed values: `ar`, `az`, `bg`, `bn`, `cs`, `da`, `de`, `el`, `en`, `es`, `fa`, `fi`, `fil`, `fr`, `gu`, `he`, `hi`, `hu`, `id`, `it`, `ja`, `ka`, `km`, `kn`, `ko`, `lt`, `lv`, `ml`, `mr`, `ms`, `ne`, `nl`, `no`, `pa`, `pl`, `pt`, `ro`, `ru`, `si`, `sk`, `sq`, `sv`, `sw`, `ta`, `te`, `th`, `tr`, `uk`, `ur`, `vi`, `yue`, `zh`
- `phonic_model` (AgentPhonicModel, optional, deprecated) — The Phonic speech-to-speech model to generate with. This field is deprecated. Use `model` instead.

### BasicError

- `error` (BasicErrorError, optional)

### ValidationError

- `error` (ValidationErrorError, required)
- `param_errors` (map from string to string, required) — Parameter-specific validation errors

### BasicErrorError

- `message` (string, required) — Error message
- `code` (string, optional) — Error code

### BuiltInToolConfig

Configuration for a simple built-in tool (`keypad_input`, `natural_conversation_ending`, or `web_search`).

- `speech_before_tool_call` (enum, required) — Controls whether the assistant speaks before the tool is called. `required`: the assistant must speak first. `optional`: the model decides. `suppressed`: the assistant is strongly instructed to stay silent before the call (best effort).
  - Allowed values: `required`, `optional`, `suppressed`

### WebSearchToolConfig

Configuration for the `web_search` built-in tool in an agent's `built_in_tool_configs`.

- `speech_before_tool_call` (enum, required) — Controls whether the agent speaks before the tool is called. `required`: the agent must speak first. `optional`: the model decides. `suppressed`: the agent is strongly instructed to stay silent before the call (best effort).
  - Allowed values: `required`, `optional`, `suppressed`
- `can_run_during_user_speech` (boolean, optional, default: false) — When true, the agent can call web search while the user is still speaking. Setting it to true requires the feature to be enabled for your organization; contact Phonic to get access.

### ChooseNotToRespondToolConfig

Configuration for the `choose_not_to_respond` built-in tool.

- `respond_after_sec` (double, optional, nullable) — Number of seconds to wait after the tool fires before the assistant speaks a follow-up if the user stays silent. When null, the assistant stays silent (default).

### DataRetentionPolicy0

Zero data retention mode. No transcripts or audio recordings are retained.

- `zero_data_retention` (boolean, required) — When `true`, no transcripts or audio recordings are retained.

### DataRetentionPolicy1

Standard data retention with configurable deletion windows.

- `zero_data_retention` (boolean, required) — Must be `false` for standard data retention.
- `transcripts` (DataRetentionPolicyOneOf1Transcripts, required)
- `audio_recordings` (DataRetentionPolicyOneOf1AudioRecordings, required)

### AgentProject

The project the agent belongs to.

- `id` (string, required)
- `name` (string, required)

### AgentTemplateVariables

- `default_value` (string, required, nullable)

### AgentToolsItems

- enum
  - Allowed values: `keypad_input`, `natural_conversation_ending`, `choose_not_to_respond`, `web_search`
- string

### AgentModel

The Phonic speech-to-speech model to generate with. Omit it to use the current default model.

- enum
  - Allowed values: `phonic-0.5`, `phonic-1`
- string

### AgentPronunciationDictionaryItems

- `word` (string, required)
- `pronunciation` (string, required)

### AgentConfigurationEndpoint

When not `null`, the agent will call this endpoint to get configuration options.

- `url` (string, required)
- `headers` (map from string to string, required)
- `timeout_ms` (integer, required) — The timeout for the configuration endpoint in milliseconds.

### AgentIntegration

A third-party integration enabled for an agent.

- `account_id` (string, required) — The connected account ID.
- `account_name` (string, required, nullable) — The connected account name.
- `action_names` (list of string, required) — The integration actions available to the agent.
- `app_slug` (string, required) — The slug identifying the integration app.

### AgentPhonicModel

The Phonic speech-to-speech model to generate with. This field is deprecated. Use `model` instead.

- enum
  - Allowed values: `phonic-0.5`, `phonic-1`
- string

### ValidationErrorError

- `message` (string, required) — Error message

### DataRetentionPolicyOneOf1Transcripts

- `delete_after_hours` (integer, required, nullable) — Number of hours after which transcripts are deleted. Null means transcripts are retained indefinitely.

### DataRetentionPolicyOneOf1AudioRecordings

- `delete_after_hours` (integer, required, nullable) — Number of hours after which audio recordings are deleted. Null means audio recordings are retained indefinitely.

## Examples

### Upsert agent response

**Response**

```json
{
  "agent": {
    "id": "agent_12cf6e88-c254-4d3e-a149-a7f1bdd22783",
    "name": "support-agent",
    "phone_numbers": [
      "+1234567890"
    ],
    "project": {
      "id": "proj_ad0334f1-2487-4155-9df3-abd8129b29ad",
      "name": "customer-support"
    },
    "timezone": "America/Los_Angeles",
    "voice_id": "sabrina",
    "additional_voice_ids": [],
    "audio_format": "pcm_44100",
    "audio_speed": 1,
    "background_noise_level": 0,
    "background_noise": null,
    "generate_welcome_message": false,
    "is_welcome_message_interruptible": true,
    "listen_only_inbound_enabled": false,
    "listen_only_inbound_message": null,
    "welcome_message": "Hi {{customer_name}}. How can I help you today?",
    "system_prompt": "You are an expert in {{subject}}. Be friendly, helpful and concise.",
    "template_variables": {
      "customer_name": {
        "default_value": "Sean"
      },
      "subject": {
        "default_value": "Chess"
      }
    },
    "tools": [
      "keypad_input"
    ],
    "built_in_tool_configs": {
      "tool_natural_conversation_ending": {
        "speech_before_tool_call": "suppressed"
      },
      "tool_choose_not_to_respond": {
        "respond_after_sec": 5
      }
    },
    "tasks": [
      {
        "name": "Check Availability",
        "description": "Check if the appointment is available"
      },
      {
        "name": "Book Appointment",
        "description": "Book the appointment"
      }
    ],
    "generate_no_input_poke_text": false,
    "no_input_poke_sec": 30,
    "no_input_poke_text": "Are you still there?",
    "no_input_end_conversation_sec": 180,
    "default_language": "en",
    "additional_languages": [
      "es"
    ],
    "multilingual_mode": "request",
    "push_to_talk": false,
    "intelligence_level": "standard",
    "model": "phonic-1",
    "boosted_keywords": [
      "Load ID",
      "dispatch"
    ],
    "pronunciation_dictionary": [
      {
        "word": "Phuket",
        "pronunciation": "Poo-ket"
      }
    ],
    "min_words_to_interrupt": 1,
    "configuration_endpoint": {
      "url": "https://api.example.com/config",
      "headers": {
        "Authorization": "Bearer token123"
      },
      "timeout_ms": 7000
    },
    "is_disabled": true,
    "phone_number": "+1234567890"
  },
  "inserted": true,
  "updated": false
}
```

**SDK Code**

```python Upsert agent response
import requests

url = "https://api.phonic.ai/v1/agents/upsert"

querystring = {"project":"main"}

headers = {"Authorization": "Bearer <apiKey>"}

response = requests.put(url, headers=headers, params=querystring)

print(response.json())
```

```javascript Upsert agent response
const url = 'https://api.phonic.ai/v1/agents/upsert?project=main';
const options = {method: 'PUT', headers: {Authorization: 'Bearer <apiKey>'}};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go Upsert agent response
package main

import (
	"fmt"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/agents/upsert?project=main"

	req, _ := http.NewRequest("PUT", url, nil)

	req.Header.Add("Authorization", "Bearer <apiKey>")

	res, _ := http.DefaultClient.Do(req)

	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)

	fmt.Println(res)
	fmt.Println(string(body))

}
```

```ruby Upsert agent response
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/agents/upsert?project=main")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Put.new(url)
request["Authorization"] = 'Bearer <apiKey>'

response = http.request(request)
puts response.read_body
```

```java Upsert agent response
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.put("https://api.phonic.ai/v1/agents/upsert?project=main")
  .header("Authorization", "Bearer <apiKey>")
  .asString();
```

```php Upsert agent response
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('PUT', 'https://api.phonic.ai/v1/agents/upsert?project=main', [
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
  ],
]);

echo $response->getBody();
```

```csharp Upsert agent response
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/agents/upsert?project=main");
var request = new RestRequest(Method.PUT);
request.AddHeader("Authorization", "Bearer <apiKey>");
IRestResponse response = client.Execute(request);
```

```swift Upsert agent response
import Foundation

let headers = ["Authorization": "Bearer <apiKey>"]

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/agents/upsert?project=main")! as URL,
                                        cachePolicy: .useProtocolCachePolicy,
                                    timeoutInterval: 10.0)
request.httpMethod = "PUT"
request.allHTTPHeaderFields = headers

let session = URLSession.shared
let dataTask = session.dataTask(with: request as URLRequest, completionHandler: { (data, response, error) -> Void in
  if (error != nil) {
    print(error as Any)
  } else {
    let httpResponse = response as? HTTPURLResponse
    print(httpResponse)
  }
})

dataTask.resume()
```

### agents_upsert_example

**Request**

```json
{
  "name": "support-agent",
  "additional_languages": [
    "es"
  ],
  "audio_speed": 1,
  "background_noise": null,
  "background_noise_level": 0,
  "boosted_keywords": [
    "Load ID",
    "dispatch"
  ],
  "configuration_endpoint": {
    "url": "https://api.example.com/config",
    "headers": {
      "Authorization": "Bearer token123"
    },
    "timeout_ms": 7000
  },
  "default_language": "en",
  "generate_no_input_poke_text": false,
  "generate_welcome_message": false,
  "is_welcome_message_interruptible": true,
  "min_words_to_interrupt": 1,
  "multilingual_mode": "request",
  "no_input_poke_sec": 30,
  "no_input_poke_text": "Are you still there?",
  "phone_number": "assign-automatically",
  "pronunciation_dictionary": [
    {
      "word": "Phuket",
      "pronunciation": "Poo-ket"
    }
  ],
  "push_to_talk": false,
  "system_prompt": "You are an expert in {{subject}}. Be friendly, helpful and concise.",
  "template_variables": {
    "customer_name": {
      "default_value": "David"
    },
    "subject": {
      "default_value": "Chess"
    }
  },
  "timezone": "America/Los_Angeles",
  "tools": [
    "keypad_input"
  ],
  "voice_id": "sabrina",
  "welcome_message": "Hi {{customer_name}}. How can I help you today?"
}
```

**Response**

```json
{
  "agent": {
    "id": "agent_12cf6e88-c254-4d3e-a149-a7f1bdd22783",
    "name": "support-agent",
    "phone_numbers": [
      "+1234567890"
    ],
    "project": {
      "id": "proj_ad0334f1-2487-4155-9df3-abd8129b29ad",
      "name": "customer-support"
    },
    "timezone": "America/Los_Angeles",
    "voice_id": "sabrina",
    "additional_voice_ids": [],
    "audio_format": "pcm_44100",
    "audio_speed": 1,
    "background_noise_level": 0,
    "background_noise": null,
    "generate_welcome_message": false,
    "is_welcome_message_interruptible": true,
    "listen_only_inbound_enabled": false,
    "listen_only_inbound_message": null,
    "welcome_message": "Hi {{customer_name}}. How can I help you today?",
    "system_prompt": "You are an expert in {{subject}}. Be friendly, helpful and concise.",
    "template_variables": {
      "customer_name": {
        "default_value": "Sean"
      },
      "subject": {
        "default_value": "Chess"
      }
    },
    "tools": [
      "keypad_input"
    ],
    "built_in_tool_configs": {
      "tool_natural_conversation_ending": {
        "speech_before_tool_call": "suppressed"
      },
      "tool_choose_not_to_respond": {
        "respond_after_sec": 5
      }
    },
    "tasks": [
      {
        "name": "Check Availability",
        "description": "Check if the appointment is available"
      },
      {
        "name": "Book Appointment",
        "description": "Book the appointment"
      }
    ],
    "generate_no_input_poke_text": false,
    "no_input_poke_sec": 30,
    "no_input_poke_text": "Are you still there?",
    "no_input_end_conversation_sec": 180,
    "default_language": "en",
    "additional_languages": [
      "es"
    ],
    "multilingual_mode": "request",
    "push_to_talk": false,
    "intelligence_level": "standard",
    "model": "phonic-1",
    "boosted_keywords": [
      "Load ID",
      "dispatch"
    ],
    "pronunciation_dictionary": [
      {
        "word": "Phuket",
        "pronunciation": "Poo-ket"
      }
    ],
    "min_words_to_interrupt": 1,
    "configuration_endpoint": {
      "url": "https://api.example.com/config",
      "headers": {
        "Authorization": "Bearer token123"
      },
      "timeout_ms": 7000
    },
    "is_disabled": true,
    "phone_number": "+1234567890"
  },
  "inserted": true,
  "updated": false
}
```

**SDK Code**

```python agents_upsert_example
import requests

url = "https://api.phonic.ai/v1/agents/upsert"

querystring = {"project":"main"}

payload = {
    "name": "support-agent",
    "additional_languages": ["es"],
    "audio_speed": 1,
    "background_noise": None,
    "background_noise_level": 0,
    "boosted_keywords": ["Load ID", "dispatch"],
    "configuration_endpoint": {
        "url": "https://api.example.com/config",
        "headers": { "Authorization": "Bearer token123" },
        "timeout_ms": 7000
    },
    "default_language": "en",
    "generate_no_input_poke_text": False,
    "generate_welcome_message": False,
    "is_welcome_message_interruptible": True,
    "min_words_to_interrupt": 1,
    "multilingual_mode": "request",
    "no_input_poke_sec": 30,
    "no_input_poke_text": "Are you still there?",
    "phone_number": "assign-automatically",
    "pronunciation_dictionary": [
        {
            "word": "Phuket",
            "pronunciation": "Poo-ket"
        }
    ],
    "push_to_talk": False,
    "system_prompt": "You are an expert in {{subject}}. Be friendly, helpful and concise.",
    "template_variables": {
        "customer_name": { "default_value": "David" },
        "subject": { "default_value": "Chess" }
    },
    "timezone": "America/Los_Angeles",
    "tools": ["keypad_input"],
    "voice_id": "sabrina",
    "welcome_message": "Hi {{customer_name}}. How can I help you today?"
}
headers = {
    "Authorization": "Bearer <apiKey>",
    "Content-Type": "application/json"
}

response = requests.put(url, json=payload, headers=headers, params=querystring)

print(response.json())
```

```javascript agents_upsert_example
const url = 'https://api.phonic.ai/v1/agents/upsert?project=main';
const options = {
  method: 'PUT',
  headers: {Authorization: 'Bearer <apiKey>', 'Content-Type': 'application/json'},
  body: '{"name":"support-agent","additional_languages":["es"],"audio_speed":1,"background_noise":null,"background_noise_level":0,"boosted_keywords":["Load ID","dispatch"],"configuration_endpoint":{"url":"https://api.example.com/config","headers":{"Authorization":"Bearer token123"},"timeout_ms":7000},"default_language":"en","generate_no_input_poke_text":false,"generate_welcome_message":false,"is_welcome_message_interruptible":true,"min_words_to_interrupt":1,"multilingual_mode":"request","no_input_poke_sec":30,"no_input_poke_text":"Are you still there?","phone_number":"assign-automatically","pronunciation_dictionary":[{"word":"Phuket","pronunciation":"Poo-ket"}],"push_to_talk":false,"system_prompt":"You are an expert in {{subject}}. Be friendly, helpful and concise.","template_variables":{"customer_name":{"default_value":"David"},"subject":{"default_value":"Chess"}},"timezone":"America/Los_Angeles","tools":["keypad_input"],"voice_id":"sabrina","welcome_message":"Hi {{customer_name}}. How can I help you today?"}'
};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go agents_upsert_example
package main

import (
	"fmt"
	"strings"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/agents/upsert?project=main"

	payload := strings.NewReader("{\n  \"name\": \"support-agent\",\n  \"additional_languages\": [\n    \"es\"\n  ],\n  \"audio_speed\": 1,\n  \"background_noise\": null,\n  \"background_noise_level\": 0,\n  \"boosted_keywords\": [\n    \"Load ID\",\n    \"dispatch\"\n  ],\n  \"configuration_endpoint\": {\n    \"url\": \"https://api.example.com/config\",\n    \"headers\": {\n      \"Authorization\": \"Bearer token123\"\n    },\n    \"timeout_ms\": 7000\n  },\n  \"default_language\": \"en\",\n  \"generate_no_input_poke_text\": false,\n  \"generate_welcome_message\": false,\n  \"is_welcome_message_interruptible\": true,\n  \"min_words_to_interrupt\": 1,\n  \"multilingual_mode\": \"request\",\n  \"no_input_poke_sec\": 30,\n  \"no_input_poke_text\": \"Are you still there?\",\n  \"phone_number\": \"assign-automatically\",\n  \"pronunciation_dictionary\": [\n    {\n      \"word\": \"Phuket\",\n      \"pronunciation\": \"Poo-ket\"\n    }\n  ],\n  \"push_to_talk\": false,\n  \"system_prompt\": \"You are an expert in {{subject}}. Be friendly, helpful and concise.\",\n  \"template_variables\": {\n    \"customer_name\": {\n      \"default_value\": \"David\"\n    },\n    \"subject\": {\n      \"default_value\": \"Chess\"\n    }\n  },\n  \"timezone\": \"America/Los_Angeles\",\n  \"tools\": [\n    \"keypad_input\"\n  ],\n  \"voice_id\": \"sabrina\",\n  \"welcome_message\": \"Hi {{customer_name}}. How can I help you today?\"\n}")

	req, _ := http.NewRequest("PUT", url, payload)

	req.Header.Add("Authorization", "Bearer <apiKey>")
	req.Header.Add("Content-Type", "application/json")

	res, _ := http.DefaultClient.Do(req)

	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)

	fmt.Println(res)
	fmt.Println(string(body))

}
```

```ruby agents_upsert_example
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/agents/upsert?project=main")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Put.new(url)
request["Authorization"] = 'Bearer <apiKey>'
request["Content-Type"] = 'application/json'
request.body = "{\n  \"name\": \"support-agent\",\n  \"additional_languages\": [\n    \"es\"\n  ],\n  \"audio_speed\": 1,\n  \"background_noise\": null,\n  \"background_noise_level\": 0,\n  \"boosted_keywords\": [\n    \"Load ID\",\n    \"dispatch\"\n  ],\n  \"configuration_endpoint\": {\n    \"url\": \"https://api.example.com/config\",\n    \"headers\": {\n      \"Authorization\": \"Bearer token123\"\n    },\n    \"timeout_ms\": 7000\n  },\n  \"default_language\": \"en\",\n  \"generate_no_input_poke_text\": false,\n  \"generate_welcome_message\": false,\n  \"is_welcome_message_interruptible\": true,\n  \"min_words_to_interrupt\": 1,\n  \"multilingual_mode\": \"request\",\n  \"no_input_poke_sec\": 30,\n  \"no_input_poke_text\": \"Are you still there?\",\n  \"phone_number\": \"assign-automatically\",\n  \"pronunciation_dictionary\": [\n    {\n      \"word\": \"Phuket\",\n      \"pronunciation\": \"Poo-ket\"\n    }\n  ],\n  \"push_to_talk\": false,\n  \"system_prompt\": \"You are an expert in {{subject}}. Be friendly, helpful and concise.\",\n  \"template_variables\": {\n    \"customer_name\": {\n      \"default_value\": \"David\"\n    },\n    \"subject\": {\n      \"default_value\": \"Chess\"\n    }\n  },\n  \"timezone\": \"America/Los_Angeles\",\n  \"tools\": [\n    \"keypad_input\"\n  ],\n  \"voice_id\": \"sabrina\",\n  \"welcome_message\": \"Hi {{customer_name}}. How can I help you today?\"\n}"

response = http.request(request)
puts response.read_body
```

```java agents_upsert_example
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.put("https://api.phonic.ai/v1/agents/upsert?project=main")
  .header("Authorization", "Bearer <apiKey>")
  .header("Content-Type", "application/json")
  .body("{\n  \"name\": \"support-agent\",\n  \"additional_languages\": [\n    \"es\"\n  ],\n  \"audio_speed\": 1,\n  \"background_noise\": null,\n  \"background_noise_level\": 0,\n  \"boosted_keywords\": [\n    \"Load ID\",\n    \"dispatch\"\n  ],\n  \"configuration_endpoint\": {\n    \"url\": \"https://api.example.com/config\",\n    \"headers\": {\n      \"Authorization\": \"Bearer token123\"\n    },\n    \"timeout_ms\": 7000\n  },\n  \"default_language\": \"en\",\n  \"generate_no_input_poke_text\": false,\n  \"generate_welcome_message\": false,\n  \"is_welcome_message_interruptible\": true,\n  \"min_words_to_interrupt\": 1,\n  \"multilingual_mode\": \"request\",\n  \"no_input_poke_sec\": 30,\n  \"no_input_poke_text\": \"Are you still there?\",\n  \"phone_number\": \"assign-automatically\",\n  \"pronunciation_dictionary\": [\n    {\n      \"word\": \"Phuket\",\n      \"pronunciation\": \"Poo-ket\"\n    }\n  ],\n  \"push_to_talk\": false,\n  \"system_prompt\": \"You are an expert in {{subject}}. Be friendly, helpful and concise.\",\n  \"template_variables\": {\n    \"customer_name\": {\n      \"default_value\": \"David\"\n    },\n    \"subject\": {\n      \"default_value\": \"Chess\"\n    }\n  },\n  \"timezone\": \"America/Los_Angeles\",\n  \"tools\": [\n    \"keypad_input\"\n  ],\n  \"voice_id\": \"sabrina\",\n  \"welcome_message\": \"Hi {{customer_name}}. How can I help you today?\"\n}")
  .asString();
```

```php agents_upsert_example
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('PUT', 'https://api.phonic.ai/v1/agents/upsert?project=main', [
  'body' => '{
  "name": "support-agent",
  "additional_languages": [
    "es"
  ],
  "audio_speed": 1,
  "background_noise": null,
  "background_noise_level": 0,
  "boosted_keywords": [
    "Load ID",
    "dispatch"
  ],
  "configuration_endpoint": {
    "url": "https://api.example.com/config",
    "headers": {
      "Authorization": "Bearer token123"
    },
    "timeout_ms": 7000
  },
  "default_language": "en",
  "generate_no_input_poke_text": false,
  "generate_welcome_message": false,
  "is_welcome_message_interruptible": true,
  "min_words_to_interrupt": 1,
  "multilingual_mode": "request",
  "no_input_poke_sec": 30,
  "no_input_poke_text": "Are you still there?",
  "phone_number": "assign-automatically",
  "pronunciation_dictionary": [
    {
      "word": "Phuket",
      "pronunciation": "Poo-ket"
    }
  ],
  "push_to_talk": false,
  "system_prompt": "You are an expert in {{subject}}. Be friendly, helpful and concise.",
  "template_variables": {
    "customer_name": {
      "default_value": "David"
    },
    "subject": {
      "default_value": "Chess"
    }
  },
  "timezone": "America/Los_Angeles",
  "tools": [
    "keypad_input"
  ],
  "voice_id": "sabrina",
  "welcome_message": "Hi {{customer_name}}. How can I help you today?"
}',
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
    'Content-Type' => 'application/json',
  ],
]);

echo $response->getBody();
```

```csharp agents_upsert_example
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/agents/upsert?project=main");
var request = new RestRequest(Method.PUT);
request.AddHeader("Authorization", "Bearer <apiKey>");
request.AddHeader("Content-Type", "application/json");
request.AddParameter("application/json", "{\n  \"name\": \"support-agent\",\n  \"additional_languages\": [\n    \"es\"\n  ],\n  \"audio_speed\": 1,\n  \"background_noise\": null,\n  \"background_noise_level\": 0,\n  \"boosted_keywords\": [\n    \"Load ID\",\n    \"dispatch\"\n  ],\n  \"configuration_endpoint\": {\n    \"url\": \"https://api.example.com/config\",\n    \"headers\": {\n      \"Authorization\": \"Bearer token123\"\n    },\n    \"timeout_ms\": 7000\n  },\n  \"default_language\": \"en\",\n  \"generate_no_input_poke_text\": false,\n  \"generate_welcome_message\": false,\n  \"is_welcome_message_interruptible\": true,\n  \"min_words_to_interrupt\": 1,\n  \"multilingual_mode\": \"request\",\n  \"no_input_poke_sec\": 30,\n  \"no_input_poke_text\": \"Are you still there?\",\n  \"phone_number\": \"assign-automatically\",\n  \"pronunciation_dictionary\": [\n    {\n      \"word\": \"Phuket\",\n      \"pronunciation\": \"Poo-ket\"\n    }\n  ],\n  \"push_to_talk\": false,\n  \"system_prompt\": \"You are an expert in {{subject}}. Be friendly, helpful and concise.\",\n  \"template_variables\": {\n    \"customer_name\": {\n      \"default_value\": \"David\"\n    },\n    \"subject\": {\n      \"default_value\": \"Chess\"\n    }\n  },\n  \"timezone\": \"America/Los_Angeles\",\n  \"tools\": [\n    \"keypad_input\"\n  ],\n  \"voice_id\": \"sabrina\",\n  \"welcome_message\": \"Hi {{customer_name}}. How can I help you today?\"\n}", ParameterType.RequestBody);
IRestResponse response = client.Execute(request);
```

```swift agents_upsert_example
import Foundation

let headers = [
  "Authorization": "Bearer <apiKey>",
  "Content-Type": "application/json"
]
let parameters = [
  "name": "support-agent",
  "additional_languages": ["es"],
  "audio_speed": 1,
  "background_noise": ,
  "background_noise_level": 0,
  "boosted_keywords": ["Load ID", "dispatch"],
  "configuration_endpoint": [
    "url": "https://api.example.com/config",
    "headers": ["Authorization": "Bearer token123"],
    "timeout_ms": 7000
  ],
  "default_language": "en",
  "generate_no_input_poke_text": false,
  "generate_welcome_message": false,
  "is_welcome_message_interruptible": true,
  "min_words_to_interrupt": 1,
  "multilingual_mode": "request",
  "no_input_poke_sec": 30,
  "no_input_poke_text": "Are you still there?",
  "phone_number": "assign-automatically",
  "pronunciation_dictionary": [
    [
      "word": "Phuket",
      "pronunciation": "Poo-ket"
    ]
  ],
  "push_to_talk": false,
  "system_prompt": "You are an expert in {{subject}}. Be friendly, helpful and concise.",
  "template_variables": [
    "customer_name": ["default_value": "David"],
    "subject": ["default_value": "Chess"]
  ],
  "timezone": "America/Los_Angeles",
  "tools": ["keypad_input"],
  "voice_id": "sabrina",
  "welcome_message": "Hi {{customer_name}}. How can I help you today?"
] as [String : Any]

let postData = JSONSerialization.data(withJSONObject: parameters, options: [])

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/agents/upsert?project=main")! as URL,
                                        cachePolicy: .useProtocolCachePolicy,
                                    timeoutInterval: 10.0)
request.httpMethod = "PUT"
request.allHTTPHeaderFields = headers
request.httpBody = postData as Data

let session = URLSession.shared
let dataTask = session.dataTask(with: request as URLRequest, completionHandler: { (data, response, error) -> Void in
  if (error != nil) {
    print(error as Any)
  } else {
    let httpResponse = response as? HTTPURLResponse
    print(httpResponse)
  }
})

dataTask.resume()
```