> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Get

GET https://api.phonic.ai/v1/conversations/{id}

Returns a conversation by ID.

Reference: https://docs.phonic.ai/api-reference/conversations/get

## Authentication

- `Authorization` header (bearer token, required) — Bearer authentication header of the form `Bearer <PHONIC_API_KEY>`. Manage your API keys [here](https://phonic.co/api-keys).

## Request

### Path parameters

- `id` (string, required) — The ID of the conversation to get.

### Query parameters

- `audio_container` (enum, optional, default: wav.gz) — Format of the presigned `audio_url` in the response.
  - Allowed values: `wav.gz`, `wav`

## Response

### 200

Success response

- `conversation` (Conversation, required)

## Errors

### 401 Unauthorized Error

Unauthorized (authentication missing or invalid)

- `error` (BasicErrorError, optional)

### 403 Forbidden Error

Forbidden

- `error` (BasicErrorError, optional)

### 404 Not Found Error

Conversation not found

- `error` (BasicErrorError, optional)

### 500 Internal Server Error

Internal server error

- `error` (BasicErrorError, optional)

## Types

### Conversation

- `id` (string, required) — The conversation ID.
- `agent` (ConversationAgent, required, nullable) — The agent associated with the conversation.
- `workspace` (string, required) — The organization/workspace name.
- `project` (ConversationProject, required) — The project associated with the conversation.
- `external_id` (string, required, nullable) — External ID for conversation tracking.
- `origin` (enum, required) — The origin of the conversation.
  - Allowed values: `web`, `web-playground`, `web-demo`, `direct`, `livekit-agents-py`, `livekit-agents-js`, `sdk-py`, `sdk-js`, `inbound`, `telephony-inbound`, `outbound`, `telephony-outbound`, `replay`
- `model` (ConversationModel, required) — The Phonic speech-to-speech model used for the conversation.
- `generate_welcome_message` (boolean, required) — Will be `true` if welcome message was automatically generated.
- `is_welcome_message_interruptible` (boolean, required) — When `false`, the welcome message will not be interruptible by the user.
- `listen_only` (boolean, required) — Whether this conversation used listen-only mode. The resolved greeting is stored in `welcome_message`.
- `welcome_message` (string, required, nullable) — Welcome message played at start. Will be `null` when `generate_welcome_message` is `true`.
- `template_variables` (map from string to string, required) — Template variables used in the conversation.
- `input_format` (string, required) — Audio input format.
- `output_format` (string, required) — Audio output format.
- `background_noise_level` (double, required) — Background noise level used in the conversation.
- `background_noise` (enum, required) — The background noise type used in the conversation.
  - Allowed values: `office`, `call-center`, `coffee-shop`
- `live_transcript` (string, required, nullable) — Live transcript of the conversation.
- `post_call_transcript` (string, required, nullable) — Post-call processed transcript.
- `duration_ms` (double, required, nullable) — Duration of the conversation in milliseconds.
- `audio_url` (string, required, nullable) — Presigned URL to the conversation audio file. Expires in 1 day.
- `started_at` (string, required, nullable) — When the conversation started.
- `ended_at` (string, required, nullable) — When the conversation ended.
- `ended_by` (enum, required) — Who or what ended the conversation.
  - Allowed values: `user`, `user_canceled`, `user_validation_failed`, `assistant`, `assistant_silence_limit_reached`, `configuration_endpoint_timed_out`, `configuration_endpoint_error`, `configuration_endpoint_invalid_response`, `error`
- `boosted_keywords` (list of string, required, nullable) — These words, or short phrases, are more accurately recognized by the model.
- `pronunciation_dictionary` (list of ConversationPronunciationDictionaryItems, required) — Array of `{ word, pronunciation }` entries. Words must be unique.
- `min_words_to_interrupt` (integer, required, default: 1) — Minimum number of words required to interrupt the assistant.
- `default_language` (enum, required) — ISO 639-1 language code that sets the agent's default language to recognize and speak. Welcome message and no input poke text should be in this language.
  - Allowed values: `ar`, `az`, `bg`, `bn`, `cs`, `da`, `de`, `el`, `en`, `es`, `fa`, `fi`, `fil`, `fr`, `gu`, `he`, `hi`, `hu`, `id`, `it`, `ja`, `ka`, `km`, `kn`, `ko`, `lt`, `lv`, `ml`, `mr`, `ms`, `ne`, `nl`, `no`, `pa`, `pl`, `pt`, `ro`, `ru`, `si`, `sk`, `sq`, `sv`, `sw`, `ta`, `te`, `th`, `tr`, `uk`, `ur`, `vi`, `yue`, `zh`
- `additional_languages` (list of enum, required, nullable) — Array of additional ISO 639-1 language codes that the agent should be able to recognize and speak. Should not include `default_language`. When `multilingual_mode` is `"auto"`, a maximum of 2 additional languages is allowed.
  - Allowed values: `ar`, `az`, `bg`, `bn`, `cs`, `da`, `de`, `el`, `en`, `es`, `fa`, `fi`, `fil`, `fr`, `gu`, `he`, `hi`, `hu`, `id`, `it`, `ja`, `ka`, `km`, `kn`, `ko`, `lt`, `lv`, `ml`, `mr`, `ms`, `ne`, `nl`, `no`, `pa`, `pl`, `pt`, `ro`, `ru`, `si`, `sk`, `sq`, `sv`, `sw`, `ta`, `te`, `th`, `tr`, `uk`, `ur`, `vi`, `yue`, `zh`
- `multilingual_mode` (enum, required, default: request) — If `"auto"`, each user audio is automatically identified for the language to respond in. If `"request"`, user must request to change language (recommended). If `"initial"` the first turn user audio determines the language for the rest of the conversation.
  - Allowed values: `auto`, `request`, `initial`
- `push_to_talk` (boolean, required, default: false) — Push to talk mode. User must send mute/unmute messages to turn on/off listening to audio. Defaults to false.
- `no_input_poke_sec` (integer, required, nullable) — Number of seconds of silence before a poke message is sent. `null` means the poke message is disabled.
- `no_input_poke_text` (string, required, nullable) — The message to send after the specified silence. Relevant only if `no_input_poke_sec` is not `null`. Ignored when generate_no_input_poke_text is true.
- `no_input_end_conversation_sec` (integer, required, nullable) — Seconds of silence before the conversation is ended.
- `task_results` (map from string to any, required) — Results from conversation evaluations and extractions.
- `items` (list of ConversationItem, required) — Array of conversation items (turns).
- `call_info` (ConversationCallInfo, required, nullable) — Phone call metadata. `null` for non-phone call conversations.
- `analysis` (ConversationAnalysis, required) — Analysis of the conversation including latencies and interruptions.
- `system_prompt` (string, optional, nullable) — System prompt used in the conversation.
- `summary` (string, optional, nullable) — Summary of the conversation.
- `intelligence_level` (enum, optional) — The intelligence level used for the conversation.
  - Allowed values: `standard`, `high`
- `heard_languages` (list of enum, optional) — Distinct languages heard from the user across the conversation, in order of first appearance. Empty for conversations predating language tracking.
  - Allowed values: `ar`, `az`, `bg`, `bn`, `cs`, `da`, `de`, `el`, `en`, `es`, `fa`, `fi`, `fil`, `fr`, `gu`, `he`, `hi`, `hu`, `id`, `it`, `ja`, `ka`, `km`, `kn`, `ko`, `lt`, `lv`, `ml`, `mr`, `ms`, `ne`, `nl`, `no`, `pa`, `pl`, `pt`, `ro`, `ru`, `si`, `sk`, `sq`, `sv`, `sw`, `ta`, `te`, `th`, `tr`, `uk`, `ur`, `vi`, `yue`, `zh`
- `generate_no_input_poke_text` (boolean, optional, nullable) — Whether the no-input poke text was generated by AI.
- `websocket_timeout_sec` (double, optional) — The WebSocket idle timeout in seconds.
- `vad_prebuffer_duration_ms` (integer, optional, nullable) — Voice activity detection prebuffer duration in milliseconds. `null` when not applicable or unknown (e.g. push-to-talk, or legacy stored conversations).
- `vad_min_speech_duration_ms` (integer, optional, nullable) — Minimum speech duration for voice activity detection in milliseconds. `null` when not applicable or unknown.
- `vad_min_silence_duration_ms` (integer, optional, nullable) — Minimum silence duration for voice activity detection in milliseconds. `null` when not applicable or unknown.
- `vad_threshold` (double, optional, nullable) — Voice activity detection threshold. `null` when not applicable or unknown.
- `is_redacted` (boolean, optional) — Whether PII and PHI have been redacted from the conversation.
- `redacted_transcript` (string, optional, nullable) — The redacted transcript of the conversation. `null` when the conversation is not redacted.
- `metadata` (map from string to any, optional, nullable) — Arbitrary metadata associated with the conversation.
- `enable_watermarking` (boolean, optional) — Whether an inaudible watermark was embedded in the audio the agent generated during the conversation.
- `data_retention_policy` (DataRetentionPolicy, optional) — Controls how long transcripts and audio recordings are retained before deletion.
- `deletion_info` (ConversationDeletionInfo, optional) — Information about when transcripts and audio recordings are or were scheduled to be deleted.
- `enable_assistant_backchannel` (boolean, optional) — Whether the assistant produced backchannel responses during the conversation.
- `assistant_backchannel_aggressiveness` (double, optional, nullable) — How aggressively the assistant produced backchannel responses during the conversation.
- `phonic_model` (ConversationPhonicModel, optional, deprecated) — The Phonic speech-to-speech model used for the conversation. This field is deprecated. Use `model` instead.
- `languages` (list of string, optional, deprecated) — Array of ISO 639-1 language codes recognized by the model. This field is deprecated. Use `default_language` and `additional_languages` instead.

### BasicErrorError

- `message` (string, required) — Error message
- `code` (string, optional) — Error code

### ConversationAgent

The agent associated with the conversation.

- `id` (string, required) — The ID of the agent.
- `name` (string, required) — The name of the agent.
- `is_deleted` (boolean, required) — Whether the agent has been deleted.

### ConversationProject

The project associated with the conversation.

- `id` (string, required) — The ID of the project.
- `name` (string, required) — The name of the project.

### ConversationModel

The Phonic speech-to-speech model used for the conversation.

- enum
  - Allowed values: `phonic-0.5`, `phonic-1`
- string

### ConversationPronunciationDictionaryItems

- `word` (string, required)
- `pronunciation` (string, required)

### ConversationItem

- `id` (string, required) — The conversation item ID.
- `item_idx` (integer, required) — Index of the item in the conversation.
- `role` (enum, required) — Who spoke in this turn.
  - Allowed values: `user`, `assistant`
- `live_transcript` (string, required, nullable) — Live transcript of this turn. `null` when the turn has been redacted.
- `post_call_transcript` (string, required, nullable) — Post-call processed transcript.
- `duration_ms` (double, required) — Duration of this turn in milliseconds.
- `started_at` (string, required) — When this turn started.
- `tool_calls` (list of ConversationItemToolCallsItems, required) — Tool calls made during this turn. Tool calls made while the user is still speaking are attached to the user's turn.
- `redacted_transcript` (string, optional, nullable) — The redacted transcript of this turn. `null` when the turn is not redacted.
- `voice_id` (string, optional) — Voice ID used (assistant only).
- `audio_speed` (double, optional) — Audio speed used (assistant only).
- `system_prompt` (string, optional, deprecated) — System prompt used for this assistant turn.

### ConversationCallInfo

Phone call metadata. `null` for non-phone call conversations.

- `from_phone_number` (string, required) — Caller phone number in E.164 format. `"anonymous"` for inbound calls whose caller withheld their number.
- `to_phone_number` (string, required) — Callee phone number in E.164 format.
- `twilio_call_sid` (string, optional) — Twilio Call SID. Only present for user SIP trunking calls.

### ConversationAnalysis

- `id` (string, required) — The ID of the conversation analysis.
- `latencies_ms` (list of double, required) — Latencies between turns in milliseconds.
- `interruptions_count` (integer, required) — Number of interruptions in the conversation.

### DataRetentionPolicy

Controls how long transcripts and audio recordings are retained before deletion. When `zero_data_retention` is `true`, nothing is retained and `transcripts`/`audio_recordings` are omitted.

- DataRetentionPolicy0
- DataRetentionPolicy1

### ConversationDeletionInfo

Information about when transcripts and audio recordings are or were scheduled to be deleted.

- `transcripts_deleted_at` (string, required, nullable) — When the transcripts were deleted. `null` if not deleted.
- `audio_recordings_deleted_at` (string, required, nullable) — When the audio recordings were deleted. `null` if not deleted.

### ConversationPhonicModel

The Phonic speech-to-speech model used for the conversation. This field is deprecated. Use `model` instead.

- enum
  - Allowed values: `phonic-0.5`, `phonic-1`
- string

### ConversationItemToolCallsItems

- `id` (string, required) — The tool call ID.
- `tool` (ConversationItemToolCallsItemsTool, required)
- `request_body` (ConversationItemToolCallsItemsRequestBody, required, nullable) — The request body sent to the tool. Can be any JSON-serializable value.
- `response_body` (map from string to any, required, nullable) — The response body received from the tool.
- `timed_out` (boolean, required, nullable) — Whether the tool call timed out.
- `error_message` (string, required, nullable) — Error message if the tool call failed.
- `integration` (string, optional, nullable) — The integration associated with the tool, if any.
- `endpoint_method` (string, optional, nullable) — HTTP method for webhook tool calls.
- `endpoint_url` (string, optional, nullable) — URL for webhook tool calls, as called (with any `url_path` placeholders filled in).
- `endpoint_headers` (map from string to string, optional, nullable) — Headers for webhook tool calls.
- `endpoint_timeout_ms` (double, optional, nullable) — Timeout in milliseconds for webhook tool calls.
- `endpoint_called_at` (string, optional, nullable) — When the webhook endpoint was called (null on error).
- `query_params` (map from string to any, optional, nullable) — Query parameters for webhook tool calls (null on error or when no params).
- `response_status_code` (double, optional, nullable) — HTTP response status code for webhook tool calls (null on error).
- `tool_call_output_timeout_ms` (double, optional, nullable) — Timeout in milliseconds for websocket tool calls.

### DataRetentionPolicy0

Zero data retention mode. No transcripts or audio recordings are retained.

- `zero_data_retention` (boolean, required) — When `true`, no transcripts or audio recordings are retained.

### DataRetentionPolicy1

Standard data retention with configurable deletion windows.

- `zero_data_retention` (boolean, required) — Must be `false` for standard data retention.
- `transcripts` (DataRetentionPolicyOneOf1Transcripts, required)
- `audio_recordings` (DataRetentionPolicyOneOf1AudioRecordings, required)

### ConversationItemToolCallsItemsTool

- `id` (string, required) — The tool ID.
- `name` (string, required) — The tool name.

### ConversationItemToolCallsItemsRequestBody

The request body sent to the tool. Can be any JSON-serializable value.

- map from string to any
- list of any
- string
- double
- boolean

### DataRetentionPolicyOneOf1Transcripts

- `delete_after_hours` (integer, required, nullable) — Number of hours after which transcripts are deleted. Null means transcripts are retained indefinitely.

### DataRetentionPolicyOneOf1AudioRecordings

- `delete_after_hours` (integer, required, nullable) — Number of hours after which audio recordings are deleted. Null means audio recordings are retained indefinitely.

## Examples

**Response**

```json
{
  "conversation": {
    "id": "conv_12cf6e88-c254-4d3e-a149-ddf1bdd2254c",
    "agent": {
      "id": "agent_12cf6e88-c254-4d3e-a149-a7f1bdd22783",
      "name": "support-agent",
      "is_deleted": false
    },
    "workspace": "example-workspace",
    "project": {
      "id": "proj_ad0334f1-2487-4155-9df3-abd8129b29ad",
      "name": "customer-support"
    },
    "external_id": "call-123",
    "origin": "inbound",
    "model": "phonic-1",
    "generate_welcome_message": false,
    "is_welcome_message_interruptible": true,
    "listen_only": false,
    "welcome_message": "Hello {{customer_name}}, this is the {{department}} team. How can I help you today?",
    "template_variables": {
      "customer_name": "John",
      "department": "Support"
    },
    "input_format": "mulaw_8000",
    "output_format": "mulaw_8000",
    "background_noise_level": 0,
    "background_noise": null,
    "live_transcript": "User: Hi, I need help with booking an appointment.\nAssistant: Of course! I'd be happy to help you book an appointment.",
    "post_call_transcript": "User: Hi, I need help with booking an appointment.\nAssistant: Of course! I'd be happy to help you book an appointment.",
    "duration_ms": 120500,
    "audio_url": "https://example.com/audio/conv_12cf6e88.wav",
    "started_at": "2025-07-30T23:45:00.000Z",
    "ended_at": "2025-07-30T23:47:00.500Z",
    "ended_by": "user",
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
    "default_language": "en",
    "additional_languages": [
      "es"
    ],
    "multilingual_mode": "request",
    "push_to_talk": false,
    "no_input_poke_sec": 30,
    "no_input_poke_text": "Are you still there?",
    "no_input_end_conversation_sec": 180,
    "task_results": {},
    "items": [
      {
        "id": "string",
        "item_idx": 0,
        "role": "user",
        "live_transcript": "Hi, I need help with booking an appointment.",
        "post_call_transcript": "Hi, I need help with booking an appointment.",
        "duration_ms": 2500,
        "started_at": "2025-07-30T23:45:00.000Z",
        "tool_calls": []
      },
      {
        "id": "string",
        "item_idx": 1,
        "role": "assistant",
        "live_transcript": "Of course! I'd be happy to help you book an appointment.",
        "post_call_transcript": "Of course! I'd be happy to help you book an appointment.",
        "duration_ms": 3000,
        "started_at": "2025-07-30T23:45:02.500Z",
        "tool_calls": [
          {
            "id": "tool_call_f2d5c8a1-9e4b-4a7c-b3d1-6f8e2a9c5b7d",
            "tool": {
              "id": "tool_check_availability",
              "name": "check_availability"
            },
            "request_body": {
              "date": "tomorrow",
              "service": "consultation"
            },
            "response_body": {
              "available": true,
              "slots": [
                "09:00",
                "10:00",
                "14:00"
              ]
            },
            "timed_out": false,
            "error_message": null,
            "endpoint_method": "POST",
            "endpoint_url": "https://api.example.com/tools/check_availability",
            "endpoint_headers": {
              "Authorization": "Bearer token123"
            },
            "endpoint_timeout_ms": 5000,
            "endpoint_called_at": "2025-07-30T23:45:03.000Z",
            "query_params": {},
            "response_status_code": 200,
            "tool_call_output_timeout_ms": null
          }
        ],
        "voice_id": "sabrina",
        "audio_speed": 1,
        "system_prompt": "You are a helpful {{department}} assistant. The customer's name is {{customer_name}}. Help them book appointments."
      }
    ],
    "call_info": {
      "from_phone_number": "+15551234567",
      "to_phone_number": "+15559876543"
    },
    "analysis": {
      "id": "string",
      "latencies_ms": [
        1064,
        578,
        797
      ],
      "interruptions_count": 0
    },
    "vad_prebuffer_duration_ms": 500,
    "vad_min_speech_duration_ms": 50,
    "vad_min_silence_duration_ms": 800,
    "vad_threshold": 0.38
  }
}
```

**SDK Code**

```python Get conversation response
import requests

url = "https://api.phonic.ai/v1/conversations/id"

headers = {"Authorization": "Bearer <apiKey>"}

response = requests.get(url, headers=headers)

print(response.json())
```

```javascript Get conversation response
const url = 'https://api.phonic.ai/v1/conversations/id';
const options = {method: 'GET', headers: {Authorization: 'Bearer <apiKey>'}};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go Get conversation response
package main

import (
	"fmt"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/conversations/id"

	req, _ := http.NewRequest("GET", url, nil)

	req.Header.Add("Authorization", "Bearer <apiKey>")

	res, _ := http.DefaultClient.Do(req)

	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)

	fmt.Println(res)
	fmt.Println(string(body))

}
```

```ruby Get conversation response
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/conversations/id")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Get.new(url)
request["Authorization"] = 'Bearer <apiKey>'

response = http.request(request)
puts response.read_body
```

```java Get conversation response
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.get("https://api.phonic.ai/v1/conversations/id")
  .header("Authorization", "Bearer <apiKey>")
  .asString();
```

```php Get conversation response
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('GET', 'https://api.phonic.ai/v1/conversations/id', [
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
  ],
]);

echo $response->getBody();
```

```csharp Get conversation response
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/conversations/id");
var request = new RestRequest(Method.GET);
request.AddHeader("Authorization", "Bearer <apiKey>");
IRestResponse response = client.Execute(request);
```

```swift Get conversation response
import Foundation

let headers = ["Authorization": "Bearer <apiKey>"]

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/conversations/id")! as URL,
                                        cachePolicy: .useProtocolCachePolicy,
                                    timeoutInterval: 10.0)
request.httpMethod = "GET"
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