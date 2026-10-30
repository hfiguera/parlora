> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Create

POST https://api.phonic.ai/v1/agents
Content-Type: application/json

Creates a new agent in a project.

Reference: https://docs.phonic.ai/api-reference/agents/create

## Authentication

- `Authorization` header (bearer token, required) — Bearer authentication header of the form `Bearer <PHONIC_API_KEY>`. Manage your API keys [here](https://phonic.co/api-keys).

## Request

### Query parameters

- `project` (string, optional, default: main) — The name of the project to create the agent in.

### Body (application/json)

This endpoint expects a CreateAgentRequest.

- `name` (string, required) — The name of the agent. Can only contain lowercase letters, numbers and hyphens. Must be unique within the project.
- `slug` (string, optional) — URL-friendly agent slug. Can only contain lowercase letters, numbers and hyphens. Must be unique within the project.
- `phone_number` (enum, optional, nullable) — When set to `null`, the agent will not be associated with a phone number. When set to `"assign-automatically"`, the agent will be assigned a random phone number. When set to `"custom"`, you must provide `custom_phone_numbers`.
  - Allowed values: `assign-automatically`, `custom`
- `custom_phone_numbers` (list of string, optional, default: []) — Array of custom phone numbers in E.164 format (e.g., ["+1234567890", "+0987654321"]). The agent will be able to receive phone calls on any of these numbers. Required when `phone_number` is set to `"custom"`. All phone numbers must be unique.
- `timezone` (string, optional) — The timezone of the agent. Used to format system variables like `{{system_time}}`.
- `voice_id` (string, optional, default: grant) — The voice ID to use.
- `additional_voice_ids` (list of string, optional, default: []) — Additional voice IDs that, together with `voice_id`, form the agent's voice set. Each conversation is assigned one voice from the set, chosen at random with equal probability. Must not include `voice_id` and must not contain duplicates.
- `audio_format` (enum, optional, default: pcm_44100) — The audio format of the agent.
  - Allowed values: `pcm_44100`, `pcm_24000`, `pcm_16000`, `pcm_8000`, `mulaw_8000`
- `audio_speed` (double, optional, default: 1.2) — The audio speed of the agent.
- `background_noise_level` (double, optional, default: 0) — The background noise level of the agent.
- `background_noise` (enum, optional) — The background noise type. Can be "office", "call-center", "coffee-shop", or null.
  - Allowed values: `office`, `call-center`, `coffee-shop`
- `generate_welcome_message` (boolean, optional, default: false) — When `true`, the welcome message will be automatically generated and the `welcome_message` field will be ignored.
- `is_welcome_message_interruptible` (boolean, optional, default: true) — When `false`, the welcome message will not be interruptible by the user.
- `websocket_timeout_sec` (integer, optional, default: 60) — Number of seconds of inactivity before the conversation WebSocket is closed.
- `listen_only_inbound_enabled` (boolean, optional, default: false) — Play an uninterruptible welcome message on incoming calls, then transcribe the caller without responding. Silence timeout and call duration limits still apply.
- `listen_only_inbound_message` (string, optional, nullable) — Welcome message for listen-only incoming calls. Can contain template variables like `{{customer_name}}`. Must be nonempty when `listen_only_inbound_enabled` is `true`. Replaces `welcome_message` for these calls, regardless of `generate_welcome_message`.
- `welcome_message` (string, optional, nullable) — Message to play when the conversation starts. Can contain template variables like `{{customer_name}}`. Ignored when `generate_welcome_message` is `true`.
- `system_prompt` (string, optional, default: Today's date is {{system_date}} {{system_year}}. The day of week is {{system_weekday}}. The current time is {{system_time}}. The timezone for the current conversation is {{system_conversation_timezone}}. Use it only for date/time calculations. Do not infer location from it.) — Instructions for the conversation. Can contain template variables like `{{subject}}`.
- `template_variables` (map from string to CreateAgentRequestTemplateVariables, optional) — Variables that can be used in the welcome message and the system prompt.
- `tools` (list of CreateAgentRequestToolsItems, optional) — Array of built-in or custom tool names to use.
- `built_in_tool_configs` (BuiltInToolConfigs, optional) — Configuration overrides for built-in tools, keyed by built-in tool ID. Built-in tools not listed here use their default configuration.
- `tasks` (list of Task, optional) — Array of task objects with `name` and `description` fields.
- `generate_no_input_poke_text` (boolean, optional, default: false) — Whether to have the no-input poke text be generated by AI.
- `no_input_poke_sec` (integer, optional, nullable) — Number of seconds of silence before sending a poke message. `null` disables the poke message.
- `no_input_poke_text` (string, optional, default: Are you still there?) — The message to send after the specified silence. Ignored when generate_no_input_poke_text is true.
- `no_input_end_conversation_sec` (integer, optional, default: 180) — Seconds of silence before ending the conversation.
- `enable_assistant_backchannel` (boolean, optional, default: false) — When `true`, the assistant will produce backchannel responses (e.g. "mm-hmm") while the user is speaking.
- `assistant_backchannel_aggressiveness` (double, optional, default: 0.1) — How aggressively the assistant produces backchannel responses. Only relevant when `enable_assistant_backchannel` is `true`.
- `data_retention_policy` (DataRetentionPolicy, optional) — Controls how long transcripts and audio recordings are retained before deletion.
- `default_language` (enum, optional) — ISO 639-1 language code that sets the agent's default language to recognize and speak. Welcome message and no input poke text should be in this language.
  - Allowed values: `ar`, `az`, `bg`, `bn`, `cs`, `da`, `de`, `el`, `en`, `es`, `fa`, `fi`, `fil`, `fr`, `gu`, `he`, `hi`, `hu`, `id`, `it`, `ja`, `ka`, `km`, `kn`, `ko`, `lt`, `lv`, `ml`, `mr`, `ms`, `ne`, `nl`, `no`, `pa`, `pl`, `pt`, `ro`, `ru`, `si`, `sk`, `sq`, `sv`, `sw`, `ta`, `te`, `th`, `tr`, `uk`, `ur`, `vi`, `yue`, `zh`
- `additional_languages` (list of enum, optional, default: []) — Array of additional ISO 639-1 language codes that the agent should be able to recognize and speak. Should not include `default_language`. When `multilingual_mode` is `"auto"`, a maximum of 2 additional languages is allowed.
  - Allowed values: `ar`, `az`, `bg`, `bn`, `cs`, `da`, `de`, `el`, `en`, `es`, `fa`, `fi`, `fil`, `fr`, `gu`, `he`, `hi`, `hu`, `id`, `it`, `ja`, `ka`, `km`, `kn`, `ko`, `lt`, `lv`, `ml`, `mr`, `ms`, `ne`, `nl`, `no`, `pa`, `pl`, `pt`, `ro`, `ru`, `si`, `sk`, `sq`, `sv`, `sw`, `ta`, `te`, `th`, `tr`, `uk`, `ur`, `vi`, `yue`, `zh`
- `multilingual_mode` (enum, optional, default: request) — If `"auto"`, each user audio is automatically identified for the language to respond in. If `"request"`, user must request to change language (recommended). If `"initial"` the first turn user audio determines the language for the rest of the conversation.
  - Allowed values: `auto`, `request`, `initial`
- `push_to_talk` (boolean, optional, default: false) — Push to talk mode. User must send mute/unmute messages to turn on/off listening to audio. Defaults to false.
- `intelligence_level` (enum, optional, default: standard) — The intelligence level of the agent. `high` uses a more capable model for more complex reasoning, while `standard` is optimized for lower latency.
  - Allowed values: `standard`, `high`
- `model` (CreateAgentRequestModel, optional) — The Phonic speech-to-speech model to generate with. Omit it to use the current default model.
- `boosted_keywords` (list of string, optional) — These words, or short phrases, will be more accurately recognized by the agent.
- `pronunciation_dictionary` (list of CreateAgentRequestPronunciationDictionaryItems, optional) — Array of `{ word, pronunciation }` entries. Words must be unique.
- `min_words_to_interrupt` (integer, optional, default: 1) — Minimum number of words required to interrupt the assistant.
- `configuration_endpoint` (CreateAgentRequestConfigurationEndpoint, optional, nullable) — When not `null`, at the beginning of the conversation the agent will make a POST request to this endpoint to get configuration options.
- `inbound_rollout` (double, optional, default: 1) — Float between 0.0 and 1.0 representing the percentage of inbound calls handled by Agent. Defaults to `1.0`. Requires `phone_number` to be set when less than 1.0.
- `inbound_rollout_forward_phone_number` (string, optional, nullable) — E.164 formatted phone number where non-agent calls will be forwarded. Required when `inbound_rollout < 1.0`, must be `null` when `inbound_rollout = 1.0`. Defaults to `null`.
- `vad_prebuffer_duration_ms` (integer, optional, default: 500) — Voice activity detection prebuffer duration in milliseconds.
- `vad_min_speech_duration_ms` (integer, optional, default: 50) — Minimum speech duration for voice activity detection in milliseconds.
- `vad_min_silence_duration_ms` (integer, optional, default: 800) — Minimum silence duration for voice activity detection in milliseconds.
- `vad_threshold` (double, optional, default: 0.38) — Voice activity detection threshold.
- `enable_redaction` (boolean, optional, default: false) — When `true`, PII and PHI are redacted from text transcripts (e.g. replaced with tags like `[PHONE]`) and bleeped from audio recordings after the conversation ends.
- `enable_watermarking` (boolean, optional, default: false) — When `true`, an inaudible watermark is embedded in the audio the agent generates.
- `mcp_server_ids` (list of string, optional, default: []) — Array of MCP server IDs to make available to the agent.
- `observability_integrations` (list of enum, optional, default: []) — Names of observability integrations to enable for the agent. Each must be one of the supported providers.
  - Allowed values: `braintrust`
- `external_storage_policy` (string, optional, nullable) — Name of an external storage policy in the same project that conversation artifacts are delivered to. Requires zero data retention and cannot be combined with `enable_redaction`.
- `custom_phone_number` (string, optional, nullable, deprecated) — The custom phone number to use for the agent in E.164 format (e.g., +1234567890). This field is deprecated. Use `custom_phone_numbers` instead.
- `languages` (list of enum, optional, default: ["en"], deprecated) — Array of ISO 639-1 language codes that the agent should be able to recognize. This field is deprecated. Use `default_language` and `additional_languages` instead.
  - Allowed values: `ar`, `az`, `bg`, `bn`, `cs`, `da`, `de`, `el`, `en`, `es`, `fa`, `fi`, `fil`, `fr`, `gu`, `he`, `hi`, `hu`, `id`, `it`, `ja`, `ka`, `km`, `kn`, `ko`, `lt`, `lv`, `ml`, `mr`, `ms`, `ne`, `nl`, `no`, `pa`, `pl`, `pt`, `ro`, `ru`, `si`, `sk`, `sq`, `sv`, `sw`, `ta`, `te`, `th`, `tr`, `uk`, `ur`, `vi`, `yue`, `zh`
- `phonic_model` (CreateAgentRequestPhonicModel, optional, deprecated) — The Phonic speech-to-speech model to generate with. This field is deprecated. Use `model` instead.

## Response

### 201

Success response

- `id` (string, required) — The ID of the created agent.
- `name` (string, required) — The name of the created agent.

## Errors

### 400 Bad Request Error

Invalid parameters

- `error` (ValidationErrorError, required)
- `param_errors` (map from string to string, required) — Parameter-specific validation errors

### 401 Unauthorized Error

Unauthorized (authentication missing or invalid)

- `error` (BasicErrorError, optional)

### 404 Not Found Error

Project not found

- `error` (BasicErrorError, optional)

### 500 Internal Server Error

Internal server error

- `error` (BasicErrorError, optional)

## Types

### CreateAgentRequestTemplateVariables

- `default_value` (string, required)
- `is_boosted_keyword` (boolean, optional)

### CreateAgentRequestToolsItems

- enum
  - Allowed values: `keypad_input`, `natural_conversation_ending`, `choose_not_to_respond`, `web_search`
- string

### BuiltInToolConfigs

- BuiltInToolConfig: BuiltInToolConfig
- WebSearchToolConfig: WebSearchToolConfig
- ChooseNotToRespondToolConfig: ChooseNotToRespondToolConfig

### Task

- `name` (string, required) — The name of the task.
- `description` (string, required) — The description of the task.

### DataRetentionPolicy

Controls how long transcripts and audio recordings are retained before deletion. When `zero_data_retention` is `true`, nothing is retained and `transcripts`/`audio_recordings` are omitted.

- DataRetentionPolicy0
- DataRetentionPolicy1

### CreateAgentRequestModel

The Phonic speech-to-speech model to generate with. Omit it to use the current default model.

- enum
  - Allowed values: `phonic-0.5`, `phonic-1`
- string

### CreateAgentRequestPronunciationDictionaryItems

- `word` (string, required)
- `pronunciation` (string, required)

### CreateAgentRequestConfigurationEndpoint

When not `null`, at the beginning of the conversation the agent will make a POST request to this endpoint to get configuration options.

- `url` (string, required) — URL to call. Must be a publicly routable HTTPS URL without embedded credentials.
- `headers` (map from string to string, optional) — Object of key-value pairs.
- `timeout_ms` (integer, optional, default: 3000) — Timeout in milliseconds for the endpoint call.

### CreateAgentRequestPhonicModel

The Phonic speech-to-speech model to generate with. This field is deprecated. Use `model` instead.

- enum
  - Allowed values: `phonic-0.5`, `phonic-1`
- string

### ValidationErrorError

- `message` (string, required) — Error message

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

### DataRetentionPolicyOneOf1Transcripts

- `delete_after_hours` (integer, required, nullable) — Number of hours after which transcripts are deleted. Null means transcripts are retained indefinitely.

### DataRetentionPolicyOneOf1AudioRecordings

- `delete_after_hours` (integer, required, nullable) — Number of hours after which audio recordings are deleted. Null means audio recordings are retained indefinitely.

## Examples

### Created agent response

**Response**

```json
{
  "id": "agent_12cf6e88-c254-4d3e-a149-a7f1bdd22783",
  "name": "support-agent"
}
```

**SDK Code**

```python Created agent response
import requests

url = "https://api.phonic.ai/v1/agents"

querystring = {"project":"main"}

headers = {"Authorization": "Bearer <apiKey>"}

response = requests.post(url, headers=headers, params=querystring)

print(response.json())
```

```javascript Created agent response
const url = 'https://api.phonic.ai/v1/agents?project=main';
const options = {method: 'POST', headers: {Authorization: 'Bearer <apiKey>'}};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go Created agent response
package main

import (
	"fmt"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/agents?project=main"

	req, _ := http.NewRequest("POST", url, nil)

	req.Header.Add("Authorization", "Bearer <apiKey>")

	res, _ := http.DefaultClient.Do(req)

	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)

	fmt.Println(res)
	fmt.Println(string(body))

}
```

```ruby Created agent response
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/agents?project=main")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Post.new(url)
request["Authorization"] = 'Bearer <apiKey>'

response = http.request(request)
puts response.read_body
```

```java Created agent response
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.post("https://api.phonic.ai/v1/agents?project=main")
  .header("Authorization", "Bearer <apiKey>")
  .asString();
```

```php Created agent response
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('POST', 'https://api.phonic.ai/v1/agents?project=main', [
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
  ],
]);

echo $response->getBody();
```

```csharp Created agent response
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/agents?project=main");
var request = new RestRequest(Method.POST);
request.AddHeader("Authorization", "Bearer <apiKey>");
IRestResponse response = client.Execute(request);
```

```swift Created agent response
import Foundation

let headers = ["Authorization": "Bearer <apiKey>"]

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/agents?project=main")! as URL,
                                        cachePolicy: .useProtocolCachePolicy,
                                    timeoutInterval: 10.0)
request.httpMethod = "POST"
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

### agents_create_example

**Request**

```json
{
  "name": "support-agent",
  "phone_number": "assign-automatically",
  "timezone": "America/Los_Angeles",
  "voice_id": "sabrina",
  "audio_speed": 1,
  "background_noise_level": 0,
  "generate_welcome_message": false,
  "is_welcome_message_interruptible": true,
  "welcome_message": "Hi {{customer_name}}. How can I help you today?",
  "system_prompt": "You are an expert in {{subject}}. Be friendly, helpful and concise.",
  "template_variables": {
    "customer_name": {
      "default_value": "David"
    },
    "subject": {
      "default_value": "Chess"
    }
  },
  "tools": [
    "keypad_input"
  ],
  "generate_no_input_poke_text": false,
  "no_input_poke_sec": 30,
  "no_input_poke_text": "Are you still there?",
  "default_language": "en",
  "additional_languages": [
    "es"
  ],
  "multilingual_mode": "request",
  "push_to_talk": false,
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
  }
}
```

**Response**

```json
{
  "id": "agent_12cf6e88-c254-4d3e-a149-a7f1bdd22783",
  "name": "support-agent"
}
```

**SDK Code**

```python agents_create_example
import requests

url = "https://api.phonic.ai/v1/agents"

querystring = {"project":"main"}

payload = {
    "name": "support-agent",
    "phone_number": "assign-automatically",
    "timezone": "America/Los_Angeles",
    "voice_id": "sabrina",
    "audio_speed": 1,
    "background_noise_level": 0,
    "generate_welcome_message": False,
    "is_welcome_message_interruptible": True,
    "welcome_message": "Hi {{customer_name}}. How can I help you today?",
    "system_prompt": "You are an expert in {{subject}}. Be friendly, helpful and concise.",
    "template_variables": {
        "customer_name": { "default_value": "David" },
        "subject": { "default_value": "Chess" }
    },
    "tools": ["keypad_input"],
    "generate_no_input_poke_text": False,
    "no_input_poke_sec": 30,
    "no_input_poke_text": "Are you still there?",
    "default_language": "en",
    "additional_languages": ["es"],
    "multilingual_mode": "request",
    "push_to_talk": False,
    "boosted_keywords": ["Load ID", "dispatch"],
    "pronunciation_dictionary": [
        {
            "word": "Phuket",
            "pronunciation": "Poo-ket"
        }
    ],
    "min_words_to_interrupt": 1,
    "configuration_endpoint": {
        "url": "https://api.example.com/config",
        "headers": { "Authorization": "Bearer token123" },
        "timeout_ms": 7000
    }
}
headers = {
    "Authorization": "Bearer <apiKey>",
    "Content-Type": "application/json"
}

response = requests.post(url, json=payload, headers=headers, params=querystring)

print(response.json())
```

```javascript agents_create_example
const url = 'https://api.phonic.ai/v1/agents?project=main';
const options = {
  method: 'POST',
  headers: {Authorization: 'Bearer <apiKey>', 'Content-Type': 'application/json'},
  body: '{"name":"support-agent","phone_number":"assign-automatically","timezone":"America/Los_Angeles","voice_id":"sabrina","audio_speed":1,"background_noise_level":0,"generate_welcome_message":false,"is_welcome_message_interruptible":true,"welcome_message":"Hi {{customer_name}}. How can I help you today?","system_prompt":"You are an expert in {{subject}}. Be friendly, helpful and concise.","template_variables":{"customer_name":{"default_value":"David"},"subject":{"default_value":"Chess"}},"tools":["keypad_input"],"generate_no_input_poke_text":false,"no_input_poke_sec":30,"no_input_poke_text":"Are you still there?","default_language":"en","additional_languages":["es"],"multilingual_mode":"request","push_to_talk":false,"boosted_keywords":["Load ID","dispatch"],"pronunciation_dictionary":[{"word":"Phuket","pronunciation":"Poo-ket"}],"min_words_to_interrupt":1,"configuration_endpoint":{"url":"https://api.example.com/config","headers":{"Authorization":"Bearer token123"},"timeout_ms":7000}}'
};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go agents_create_example
package main

import (
	"fmt"
	"strings"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/agents?project=main"

	payload := strings.NewReader("{\n  \"name\": \"support-agent\",\n  \"phone_number\": \"assign-automatically\",\n  \"timezone\": \"America/Los_Angeles\",\n  \"voice_id\": \"sabrina\",\n  \"audio_speed\": 1,\n  \"background_noise_level\": 0,\n  \"generate_welcome_message\": false,\n  \"is_welcome_message_interruptible\": true,\n  \"welcome_message\": \"Hi {{customer_name}}. How can I help you today?\",\n  \"system_prompt\": \"You are an expert in {{subject}}. Be friendly, helpful and concise.\",\n  \"template_variables\": {\n    \"customer_name\": {\n      \"default_value\": \"David\"\n    },\n    \"subject\": {\n      \"default_value\": \"Chess\"\n    }\n  },\n  \"tools\": [\n    \"keypad_input\"\n  ],\n  \"generate_no_input_poke_text\": false,\n  \"no_input_poke_sec\": 30,\n  \"no_input_poke_text\": \"Are you still there?\",\n  \"default_language\": \"en\",\n  \"additional_languages\": [\n    \"es\"\n  ],\n  \"multilingual_mode\": \"request\",\n  \"push_to_talk\": false,\n  \"boosted_keywords\": [\n    \"Load ID\",\n    \"dispatch\"\n  ],\n  \"pronunciation_dictionary\": [\n    {\n      \"word\": \"Phuket\",\n      \"pronunciation\": \"Poo-ket\"\n    }\n  ],\n  \"min_words_to_interrupt\": 1,\n  \"configuration_endpoint\": {\n    \"url\": \"https://api.example.com/config\",\n    \"headers\": {\n      \"Authorization\": \"Bearer token123\"\n    },\n    \"timeout_ms\": 7000\n  }\n}")

	req, _ := http.NewRequest("POST", url, payload)

	req.Header.Add("Authorization", "Bearer <apiKey>")
	req.Header.Add("Content-Type", "application/json")

	res, _ := http.DefaultClient.Do(req)

	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)

	fmt.Println(res)
	fmt.Println(string(body))

}
```

```ruby agents_create_example
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/agents?project=main")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Post.new(url)
request["Authorization"] = 'Bearer <apiKey>'
request["Content-Type"] = 'application/json'
request.body = "{\n  \"name\": \"support-agent\",\n  \"phone_number\": \"assign-automatically\",\n  \"timezone\": \"America/Los_Angeles\",\n  \"voice_id\": \"sabrina\",\n  \"audio_speed\": 1,\n  \"background_noise_level\": 0,\n  \"generate_welcome_message\": false,\n  \"is_welcome_message_interruptible\": true,\n  \"welcome_message\": \"Hi {{customer_name}}. How can I help you today?\",\n  \"system_prompt\": \"You are an expert in {{subject}}. Be friendly, helpful and concise.\",\n  \"template_variables\": {\n    \"customer_name\": {\n      \"default_value\": \"David\"\n    },\n    \"subject\": {\n      \"default_value\": \"Chess\"\n    }\n  },\n  \"tools\": [\n    \"keypad_input\"\n  ],\n  \"generate_no_input_poke_text\": false,\n  \"no_input_poke_sec\": 30,\n  \"no_input_poke_text\": \"Are you still there?\",\n  \"default_language\": \"en\",\n  \"additional_languages\": [\n    \"es\"\n  ],\n  \"multilingual_mode\": \"request\",\n  \"push_to_talk\": false,\n  \"boosted_keywords\": [\n    \"Load ID\",\n    \"dispatch\"\n  ],\n  \"pronunciation_dictionary\": [\n    {\n      \"word\": \"Phuket\",\n      \"pronunciation\": \"Poo-ket\"\n    }\n  ],\n  \"min_words_to_interrupt\": 1,\n  \"configuration_endpoint\": {\n    \"url\": \"https://api.example.com/config\",\n    \"headers\": {\n      \"Authorization\": \"Bearer token123\"\n    },\n    \"timeout_ms\": 7000\n  }\n}"

response = http.request(request)
puts response.read_body
```

```java agents_create_example
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.post("https://api.phonic.ai/v1/agents?project=main")
  .header("Authorization", "Bearer <apiKey>")
  .header("Content-Type", "application/json")
  .body("{\n  \"name\": \"support-agent\",\n  \"phone_number\": \"assign-automatically\",\n  \"timezone\": \"America/Los_Angeles\",\n  \"voice_id\": \"sabrina\",\n  \"audio_speed\": 1,\n  \"background_noise_level\": 0,\n  \"generate_welcome_message\": false,\n  \"is_welcome_message_interruptible\": true,\n  \"welcome_message\": \"Hi {{customer_name}}. How can I help you today?\",\n  \"system_prompt\": \"You are an expert in {{subject}}. Be friendly, helpful and concise.\",\n  \"template_variables\": {\n    \"customer_name\": {\n      \"default_value\": \"David\"\n    },\n    \"subject\": {\n      \"default_value\": \"Chess\"\n    }\n  },\n  \"tools\": [\n    \"keypad_input\"\n  ],\n  \"generate_no_input_poke_text\": false,\n  \"no_input_poke_sec\": 30,\n  \"no_input_poke_text\": \"Are you still there?\",\n  \"default_language\": \"en\",\n  \"additional_languages\": [\n    \"es\"\n  ],\n  \"multilingual_mode\": \"request\",\n  \"push_to_talk\": false,\n  \"boosted_keywords\": [\n    \"Load ID\",\n    \"dispatch\"\n  ],\n  \"pronunciation_dictionary\": [\n    {\n      \"word\": \"Phuket\",\n      \"pronunciation\": \"Poo-ket\"\n    }\n  ],\n  \"min_words_to_interrupt\": 1,\n  \"configuration_endpoint\": {\n    \"url\": \"https://api.example.com/config\",\n    \"headers\": {\n      \"Authorization\": \"Bearer token123\"\n    },\n    \"timeout_ms\": 7000\n  }\n}")
  .asString();
```

```php agents_create_example
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('POST', 'https://api.phonic.ai/v1/agents?project=main', [
  'body' => '{
  "name": "support-agent",
  "phone_number": "assign-automatically",
  "timezone": "America/Los_Angeles",
  "voice_id": "sabrina",
  "audio_speed": 1,
  "background_noise_level": 0,
  "generate_welcome_message": false,
  "is_welcome_message_interruptible": true,
  "welcome_message": "Hi {{customer_name}}. How can I help you today?",
  "system_prompt": "You are an expert in {{subject}}. Be friendly, helpful and concise.",
  "template_variables": {
    "customer_name": {
      "default_value": "David"
    },
    "subject": {
      "default_value": "Chess"
    }
  },
  "tools": [
    "keypad_input"
  ],
  "generate_no_input_poke_text": false,
  "no_input_poke_sec": 30,
  "no_input_poke_text": "Are you still there?",
  "default_language": "en",
  "additional_languages": [
    "es"
  ],
  "multilingual_mode": "request",
  "push_to_talk": false,
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
  }
}',
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
    'Content-Type' => 'application/json',
  ],
]);

echo $response->getBody();
```

```csharp agents_create_example
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/agents?project=main");
var request = new RestRequest(Method.POST);
request.AddHeader("Authorization", "Bearer <apiKey>");
request.AddHeader("Content-Type", "application/json");
request.AddParameter("application/json", "{\n  \"name\": \"support-agent\",\n  \"phone_number\": \"assign-automatically\",\n  \"timezone\": \"America/Los_Angeles\",\n  \"voice_id\": \"sabrina\",\n  \"audio_speed\": 1,\n  \"background_noise_level\": 0,\n  \"generate_welcome_message\": false,\n  \"is_welcome_message_interruptible\": true,\n  \"welcome_message\": \"Hi {{customer_name}}. How can I help you today?\",\n  \"system_prompt\": \"You are an expert in {{subject}}. Be friendly, helpful and concise.\",\n  \"template_variables\": {\n    \"customer_name\": {\n      \"default_value\": \"David\"\n    },\n    \"subject\": {\n      \"default_value\": \"Chess\"\n    }\n  },\n  \"tools\": [\n    \"keypad_input\"\n  ],\n  \"generate_no_input_poke_text\": false,\n  \"no_input_poke_sec\": 30,\n  \"no_input_poke_text\": \"Are you still there?\",\n  \"default_language\": \"en\",\n  \"additional_languages\": [\n    \"es\"\n  ],\n  \"multilingual_mode\": \"request\",\n  \"push_to_talk\": false,\n  \"boosted_keywords\": [\n    \"Load ID\",\n    \"dispatch\"\n  ],\n  \"pronunciation_dictionary\": [\n    {\n      \"word\": \"Phuket\",\n      \"pronunciation\": \"Poo-ket\"\n    }\n  ],\n  \"min_words_to_interrupt\": 1,\n  \"configuration_endpoint\": {\n    \"url\": \"https://api.example.com/config\",\n    \"headers\": {\n      \"Authorization\": \"Bearer token123\"\n    },\n    \"timeout_ms\": 7000\n  }\n}", ParameterType.RequestBody);
IRestResponse response = client.Execute(request);
```

```swift agents_create_example
import Foundation

let headers = [
  "Authorization": "Bearer <apiKey>",
  "Content-Type": "application/json"
]
let parameters = [
  "name": "support-agent",
  "phone_number": "assign-automatically",
  "timezone": "America/Los_Angeles",
  "voice_id": "sabrina",
  "audio_speed": 1,
  "background_noise_level": 0,
  "generate_welcome_message": false,
  "is_welcome_message_interruptible": true,
  "welcome_message": "Hi {{customer_name}}. How can I help you today?",
  "system_prompt": "You are an expert in {{subject}}. Be friendly, helpful and concise.",
  "template_variables": [
    "customer_name": ["default_value": "David"],
    "subject": ["default_value": "Chess"]
  ],
  "tools": ["keypad_input"],
  "generate_no_input_poke_text": false,
  "no_input_poke_sec": 30,
  "no_input_poke_text": "Are you still there?",
  "default_language": "en",
  "additional_languages": ["es"],
  "multilingual_mode": "request",
  "push_to_talk": false,
  "boosted_keywords": ["Load ID", "dispatch"],
  "pronunciation_dictionary": [
    [
      "word": "Phuket",
      "pronunciation": "Poo-ket"
    ]
  ],
  "min_words_to_interrupt": 1,
  "configuration_endpoint": [
    "url": "https://api.example.com/config",
    "headers": ["Authorization": "Bearer token123"],
    "timeout_ms": 7000
  ]
] as [String : Any]

let postData = JSONSerialization.data(withJSONObject: parameters, options: [])

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/agents?project=main")! as URL,
                                        cachePolicy: .useProtocolCachePolicy,
                                    timeoutInterval: 10.0)
request.httpMethod = "POST"
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