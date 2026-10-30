> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Create

POST https://api.phonic.ai/v1/responses
Content-Type: application/json

Generates one or more alternative assistant responses for a conversation
you supply inline to simulate Phonic agent behavior.

This endpoint is stateless, so it does not create a new conversation or
store anything. The request carries the system prompt, a conversation so
far as `input`, and the tools the assistant may call.

There are two different types of tool configurations:

- `tool_definitions`: defined inline. Typically if you use LiveKit, this
  is where you can pass in your tool definitions.
- `tools`: predefined tools configured in Phonic, referenced by name, in
  the same shape as the STS WebSocket `config` message. Today this covers
  built-in tools such as `choose_not_to_respond` and transfer tools stored
  in `project`. Your context, webhook, MCP and WebSocket tools cannot be
  referenced here yet; define those inline as `tool_definitions`.

Each item in `input` is a user message, an assistant message (with
optional `tool_calls` or an `action`), or a `tool_call_output`. Every
assistant tool call must be followed immediately by the
`tool_call_output` item that carries its result.

A tool referenced in `tools` resolves to an `action` on the generated
response rather than a tool call - the event a live conversation would
have emitted, without the effect actually being carried out.

This is an experimental feature and must be enabled for your workspace;
otherwise, it returns `404`. Please contact our team if you would like
access.


Reference: https://docs.phonic.ai/api-reference/responses/create

## Authentication

- `Authorization` header (bearer token, required) — Bearer authentication header of the form `Bearer <PHONIC_API_KEY>`. Manage your API keys [here](https://phonic.co/api-keys).

## Request

### Body (application/json)

This endpoint expects a GenerateResponsesRequest.

- `system_prompt` (string, required) — The system prompt the assistant should follow.
- `input` (list of ResponsesInputItem, required) — The conversation so far, in order. Must contain at least one item.
- `voice_id` (string, optional, default: sabrina) — ID of the voice the assistant would speak with. It shapes how the responses are worded.
- `default_language` (enum, optional) — ISO 639-1 language code that sets the assistant's default language to recognize and speak.
  - Allowed values: `ar`, `az`, `bg`, `bn`, `cs`, `da`, `de`, `el`, `en`, `es`, `fa`, `fi`, `fil`, `fr`, `gu`, `he`, `hi`, `hu`, `id`, `it`, `ja`, `ka`, `km`, `kn`, `ko`, `lt`, `lv`, `ml`, `mr`, `ms`, `ne`, `nl`, `no`, `pa`, `pl`, `pt`, `ro`, `ru`, `si`, `sk`, `sq`, `sv`, `sw`, `ta`, `te`, `th`, `tr`, `uk`, `ur`, `vi`, `yue`, `zh`
- `additional_languages` (list of enum, optional, default: []) — Array of additional ISO 639-1 language codes that the assistant should be able to recognize and speak. Should not include `default_language`.
  - Allowed values: `ar`, `az`, `bg`, `bn`, `cs`, `da`, `de`, `el`, `en`, `es`, `fa`, `fi`, `fil`, `fr`, `gu`, `he`, `hi`, `hu`, `id`, `it`, `ja`, `ka`, `km`, `kn`, `ko`, `lt`, `lv`, `ml`, `mr`, `ms`, `ne`, `nl`, `no`, `pa`, `pl`, `pt`, `ro`, `ru`, `si`, `sk`, `sq`, `sv`, `sw`, `ta`, `te`, `th`, `tr`, `uk`, `ur`, `vi`, `yue`, `zh`
- `tool_definitions` (list of ResponsesToolDefinition, optional, default: []) — Tools defined inline for this request only. Typically if you use LiveKit, this is where you can pass in your tool definitions. Names must be unique, must not repeat a name in `tools`, and cannot be one of the names Phonic reserves for its built-in tools.
- `project` (string, optional) — Name of the project the tools referenced by name in `tools` belong to. Required whenever `tools` names a tool stored in your workspace; built-in tools can be referenced without it.
- `tools` (list of ResponsesTool, optional, default: []) — Tools the assistant may call that already exist - a built-in tool, or a transfer tool stored in `project`, referenced by name. Names must be unique and must not repeat a name in `tool_definitions`. Stored tools that are not transfer tools cannot be referenced here yet; define them inline as `tool_definitions` instead.
- `model` (GenerateResponsesRequestModel, optional) — The Phonic speech-to-speech model to generate with. Omit it to use the current default model.
- `num_responses` (integer, optional, default: 1) — Number of alternative responses to generate.
- `phonic_model` (GenerateResponsesRequestPhonicModel, optional, deprecated) — The Phonic speech-to-speech model to generate with. This field is deprecated. Use `model` instead.

## Response

### 200

Success response

- `responses` (list of GeneratedResponse, required) — The generated responses - always `num_responses` of them.

## Errors

### 400 Bad Request Error

Invalid parameters

- `error` (ValidationErrorError, required)
- `param_errors` (map from string to string, required) — Parameter-specific validation errors

### 401 Unauthorized Error

Unauthorized (authentication missing or invalid)

- `error` (BasicErrorError, optional)

### 404 Not Found Error

The responses API is not enabled for this workspace, or `project` was not found

- `error` (BasicErrorError, optional)

### 429 Too Many Requests Error

Rate limit exceeded

- `error` (BasicErrorError, optional)

### 500 Internal Server Error

Internal server error

- `error` (BasicErrorError, optional)

### 502 Bad Gateway Error

The responses service returned an invalid response

- `error` (BasicErrorError, optional)

### 503 Service Unavailable Error

The responses service is unavailable

- `error` (BasicErrorError, optional)

## Types

### ResponsesInputItem

One item of conversation history - a user message, an assistant message, or the output of an assistant tool call.

- ResponsesUserMessage: ResponsesUserMessage
- ResponsesAssistantMessage: ResponsesAssistantMessage
- ResponsesToolCallOutput: ResponsesToolCallOutput

### ResponsesToolDefinition

A tool the assistant may call, defined inline for this request only.

- `name` (string, required) — The tool name.
- `description` (string, required) — What the tool does. The model uses this to decide when to call it.
- `parameters` (ToolParametersJsonSchema, required) — A tool's parameters expressed as a raw JSON Schema object, for parameters that the flat `ToolParameter` list cannot express: nested objects, arrays of objects, `anyOf` variants, `null`, and non-string enums. Each entry in `properties` is a JSON Schema value supporting `type` (`"string"`, `"integer"`, `"number"`, `"boolean"`, `"null"`, `"array"`, `"object"`), `description`, `enum` (string parameters only), `items` (for arrays), `properties`/`required`/`additionalProperties` (for objects) and `anyOf`. Values may be nested up to 5 levels deep. Parameter names cannot be any of the reserved names that Phonic injects into every tool call: `call_info`, `conversation_id`, `from_phone_number`, `pre_tool_text`, `to_phone_number`, `twilio_call_sid`. For `custom_webhook` tools, parameter placement is supplied separately in `parameter_locations` rather than inline on the schema.
- `require_speech_before_tool_call` (boolean, optional, default: true) — When true, forces the agent to speak before executing the tool. Note this defaults to true here, unlike on the tools API, so a simulated turn matches the default a custom tool runs with in a live call.
- `forbid_tool_call_after_speech` (boolean, optional, default: false) — When true, forbids the agent from calling the tool right after it has spoken. The call is dropped and the speech is kept.

### ResponsesTool

A tool that already exists, referenced by name - either a built-in tool or a transfer tool stored in `project`. Use the object form to configure a built-in tool explicitly; a bare name uses the tool's default configuration.

- ResponsesToolName: string
- ResponsesBuiltInTool: ResponsesBuiltInTool

### GenerateResponsesRequestModel

The Phonic speech-to-speech model to generate with. Omit it to use the current default model.

- enum
  - Allowed values: `phonic-0.5`, `phonic-1`
- string

### GenerateResponsesRequestPhonicModel

The Phonic speech-to-speech model to generate with. This field is deprecated. Use `model` instead.

- enum
  - Allowed values: `phonic-0.5`, `phonic-1`
- string

### GeneratedResponse

- `text` (string, required) — The text the assistant would say. Empty when the response only makes tool calls or only takes an action.
- `tool_calls` (list of GeneratedToolCall, required) — Tool calls the assistant would make - note that the tools are not actually called.
- `action` (ResponsesAction, optional) — The action the assistant would take, when the response calls one of the tools referenced in `tools`. Note that the action is not actually carried out.

### ValidationErrorError

- `message` (string, required) — Error message

### BasicErrorError

- `message` (string, required) — Error message
- `code` (string, optional) — Error code

### ResponsesUserMessage

Something the user said.

- `role` ("user", required)
- `text` (string, required) — What the user said.

### ResponsesAssistantMessage

An assistant turn. Must carry at least one of `text`, `tool_calls`, or `action`. `tool_calls` and `action` cannot both be present.

- `role` ("assistant", required)
- `text` (string, required) — What the assistant said. Empty when the turn only made tool calls or only took an action.
- `tool_calls` (list of ResponsesToolCall, optional) — Tool calls the assistant made on this turn. Each one must be followed immediately by its matching `tool_call_output` item.
- `action` (ResponsesAction, optional) — The action the assistant took on this turn. Cannot be combined with `tool_calls`.

### ResponsesToolCallOutput

The result of an assistant tool call. Must record an outcome through `response_body`, `response_status_code`, `error_message`, `timed_out`, or `interrupted`.

- `type` ("tool_call_output", required)
- `tool_call_id` (string, required) — The `tool_call_id` of the assistant tool call this output belongs to.
- `response_body` (ResponsesToolCallOutputResponseBody, optional, nullable) — The value the tool returned. Can be any JSON-serializable value.
- `response_status_code` (integer, optional, nullable) — HTTP status code the tool returned, for tools called over HTTP.
- `timed_out` (boolean, optional) — Whether the tool call timed out.
- `error_message` (string, optional, nullable) — The error the tool call failed with.
- `interrupted` (boolean, optional) — Whether the tool call was interrupted before it finished.

### ToolParametersJsonSchema

A tool's parameters expressed as a raw JSON Schema object, for parameters that the flat `ToolParameter` list cannot express: nested objects, arrays of objects, `anyOf` variants, `null`, and non-string enums. Each entry in `properties` is a JSON Schema value supporting `type` (`"string"`, `"integer"`, `"number"`, `"boolean"`, `"null"`, `"array"`, `"object"`), `description`, `enum` (string parameters only), `items` (for arrays), `properties`/`required`/`additionalProperties` (for objects) and `anyOf`. Values may be nested up to 5 levels deep. Parameter names cannot be any of the reserved names that Phonic injects into every tool call: `call_info`, `conversation_id`, `from_phone_number`, `pre_tool_text`, `to_phone_number`, `twilio_call_sid`. For `custom_webhook` tools, parameter placement is supplied separately in `parameter_locations` rather than inline on the schema.

- `type` ("object", required)
- `properties` (map from string to any, required) — The tool's top-level parameters, as a map from parameter name to its JSON Schema.
- `required` (list of string, optional, default: []) — The names of the required top-level parameters. Every name must be defined in `properties`.
- `additionalProperties` (false, optional, default: false) — Must be `false`. Tool parameter schemas do not allow properties beyond the ones declared.

### ResponsesBuiltInTool

A built-in tool with an explicit configuration, as an alternative to referencing it by bare name (which uses the tool's default configuration). `keypad_input`, `natural_conversation_ending`, and `web_search` take a `speech_before_tool_call` config; `choose_not_to_respond` takes a `respond_after_sec` config.

- `type` ("built_in", required)
- `name` (enum, required) — The name of the built-in tool.
  - Allowed values: `keypad_input`, `natural_conversation_ending`, `choose_not_to_respond`, `web_search`
- `tool_config` (ResponsesBuiltInToolToolConfig, required) — The tool's configuration. Use `BuiltInToolConfig` for `keypad_input`, `natural_conversation_ending`, and `web_search`, or `ChooseNotToRespondToolConfig` for `choose_not_to_respond`.

### GeneratedToolCall

- `tool_call_id` (string, required) — Identifier for this tool call. Send it back as the `tool_call_id` of the matching `tool_call_output` input item.
- `tool` (GeneratedToolReference, required) — The tool the assistant wants to call.
- `request_body` (map from string to any, optional) — Arguments the assistant produced for the request body.
- `query_params` (map from string to string, optional) — Arguments the assistant produced as query parameters.

### ResponsesAction

The action the assistant takes on a turn - the event a live Phonic conversation would have emitted over the STS WebSocket, without the effect actually being carried out.

- ResponsesChoseNotToRespondAction: ResponsesChoseNotToRespondAction
- ResponsesEndedConversationAction: ResponsesEndedConversationAction
- ResponsesDtmfAction: ResponsesDtmfAction
- ResponsesTransferToPhoneNumberAction: ResponsesTransferToPhoneNumberAction
- ResponsesTransferToAgentAction: ResponsesTransferToAgentAction

### ResponsesToolCall

A tool call the assistant made earlier in the conversation.

- `tool_call_id` (string, required) — Identifier for this tool call, unique within `input`.
- `tool` (ResponsesToolReference, required) — A pointer to the tool that was called by the assistant (see ResponsesToolCall).
- `request_body` (map from string to any, optional, nullable) — Arguments the assistant passed in the request body.
- `query_params` (map from string to string, optional, nullable) — Arguments the assistant passed as query parameters. An argument cannot appear in both `request_body` and `query_params`.

### ResponsesToolCallOutputResponseBody

The value the tool returned. Can be any JSON-serializable value.

- map from string to any
- list of any
- string
- double
- boolean

### ResponsesBuiltInToolToolConfig

The tool's configuration. Use `BuiltInToolConfig` for `keypad_input`, `natural_conversation_ending`, and `web_search`, or `ChooseNotToRespondToolConfig` for `choose_not_to_respond`.

- BuiltInToolConfig: BuiltInToolConfig
- ChooseNotToRespondToolConfig: ChooseNotToRespondToolConfig

### GeneratedToolReference

The tool the assistant wants to call.

- `name` (string, required) — Name of the tool to call. Always one of the `tool_definitions` from the request.

### ResponsesChoseNotToRespondAction

The assistant stayed silent instead of responding (the `choose_not_to_respond` built-in tool).

- `type` ("assistant_chose_not_to_respond", required)
- `respond_after_sec` (double, optional, nullable) — Number of seconds the assistant would wait before speaking a follow-up if the user stays silent, echoed from the tool's configuration. When null, the assistant stays silent.

### ResponsesEndedConversationAction

The assistant ended the conversation (the `natural_conversation_ending` built-in tool).

- `type` ("assistant_ended_conversation", required)

### ResponsesDtmfAction

The assistant pressed keypad digits (the `keypad_input` built-in tool).

- `type` ("dtmf", required)
- `digits` (string, required) — The digits the assistant pressed.

### ResponsesTransferToPhoneNumberAction

The assistant transferred the call to a phone number (a `built_in_transfer_to_phone_number` tool).

- `type` ("transfer_to_phone_number", required)
- `detect_voicemail` (boolean, required) — Whether Phonic would detect whether the transfer reached a voicemail.
- `use_agent_phone_number` (boolean, required) — Whether the transfer would be placed from the agent's phone number.
- `keep_listening` (boolean, required) — Whether Phonic would keep transcribing the call after the transfer.
- `on_transfer_no_answer` (enum, required) — What Phonic would do if the transfer target does not answer. `return_to_assistant` hands control back to the agent; `keep_retrying` re-dials the target.
  - Allowed values: `return_to_assistant`, `keep_retrying`
- `phone_number` (string, optional, nullable) — The phone number the call would be transferred to, in E.164 format. Null when transferring to `sip` instead.
- `sip` (TransferSip, optional, nullable) — The SIP destination the call would be transferred to. Null when transferring to `phone_number` instead.
- `dtmf` (string, optional, nullable) — Digits to dial after the transfer connects, for navigating a phone menu. Null when there are none.

### ResponsesTransferToAgentAction

The assistant transferred the conversation to another agent (a `built_in_transfer_to_agent` tool).

- `type` ("transfer_to_agent", required)
- `agent` (string, required) — Name of the agent the conversation would be transferred to.

### ResponsesToolReference

A pointer to the tool that was called by the assistant (see ResponsesToolCall).

- `name` (string, required) — Name of the tool that was called.
- `id` (string, optional) — Optional tool ID, accepted for compatibility with tool calls copied from conversation items.

### BuiltInToolConfig

Configuration for a simple built-in tool (`keypad_input`, `natural_conversation_ending`, or `web_search`).

- `speech_before_tool_call` (enum, required) — Controls whether the assistant speaks before the tool is called. `required`: the assistant must speak first. `optional`: the model decides. `suppressed`: the assistant is strongly instructed to stay silent before the call (best effort).
  - Allowed values: `required`, `optional`, `suppressed`

### ChooseNotToRespondToolConfig

Configuration for the `choose_not_to_respond` built-in tool.

- `respond_after_sec` (double, optional, nullable) — Number of seconds to wait after the tool fires before the assistant speaks a follow-up if the user stays silent. When null, the assistant stays silent (default).

### TransferSip

A SIP destination to transfer calls to, used instead of a phone number.

- `uri` (string, required) — The SIP URI to transfer calls to, in the form `sip:user@host[:port][;transport=udp|tcp|tls]` or `sips:user@host[:port]`. `transport` is the only URI parameter allowed.
- `headers` (map from string to string, optional, default: {}) — Custom SIP headers to send with the transfer. Header names must start with `X-`, and values cannot contain line breaks. Headers require a bridged transfer (keep_listening true, or DTMF set), since a SIP REFER transfer can't carry them.

## Examples

### Generate responses

**Request**

```json
{
  "system_prompt": "You help callers find a pizza shop. Be friendly and concise.",
  "input": [
    {
      "role": "user",
      "text": "Where should I get pizza near Union Square?"
    }
  ],
  "voice_id": "sabrina",
  "default_language": "en",
  "additional_languages": [
    "es"
  ],
  "tool_definitions": [
    {
      "name": "search_pizza_shop_recs",
      "description": "Search for pizza shop recommendations.",
      "parameters": {
        "type": "object",
        "properties": {
          "location": {
            "type": "string",
            "description": "The neighborhood to search in."
          }
        },
        "required": [
          "location"
        ],
        "additionalProperties": false
      }
    }
  ],
  "model": "phonic-1",
  "num_responses": 2
}
```

**Response**

```json
{
  "responses": [
    {
      "text": "Joe's Pizza is a couple of blocks away - want the address?",
      "tool_calls": []
    },
    {
      "text": "",
      "tool_calls": [
        {
          "tool_call_id": "call_9f2c4b1a",
          "tool": {
            "name": "search_pizza_shop_recs"
          },
          "request_body": {
            "location": "Union Square"
          }
        }
      ]
    }
  ]
}
```

**SDK Code**

```python Generate responses
import requests

url = "https://api.phonic.ai/v1/responses"

payload = {
    "system_prompt": "You help callers find a pizza shop. Be friendly and concise.",
    "input": [
        {
            "role": "user",
            "text": "Where should I get pizza near Union Square?"
        }
    ],
    "voice_id": "sabrina",
    "default_language": "en",
    "additional_languages": ["es"],
    "tool_definitions": [
        {
            "name": "search_pizza_shop_recs",
            "description": "Search for pizza shop recommendations.",
            "parameters": {
                "type": "object",
                "properties": { "location": {
                        "type": "string",
                        "description": "The neighborhood to search in."
                    } },
                "required": ["location"],
                "additionalProperties": False
            }
        }
    ],
    "model": "phonic-1",
    "num_responses": 2
}
headers = {
    "Authorization": "Bearer <apiKey>",
    "Content-Type": "application/json"
}

response = requests.post(url, json=payload, headers=headers)

print(response.json())
```

```javascript Generate responses
const url = 'https://api.phonic.ai/v1/responses';
const options = {
  method: 'POST',
  headers: {Authorization: 'Bearer <apiKey>', 'Content-Type': 'application/json'},
  body: '{"system_prompt":"You help callers find a pizza shop. Be friendly and concise.","input":[{"role":"user","text":"Where should I get pizza near Union Square?"}],"voice_id":"sabrina","default_language":"en","additional_languages":["es"],"tool_definitions":[{"name":"search_pizza_shop_recs","description":"Search for pizza shop recommendations.","parameters":{"type":"object","properties":{"location":{"type":"string","description":"The neighborhood to search in."}},"required":["location"],"additionalProperties":false}}],"model":"phonic-1","num_responses":2}'
};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go Generate responses
package main

import (
	"fmt"
	"strings"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/responses"

	payload := strings.NewReader("{\n  \"system_prompt\": \"You help callers find a pizza shop. Be friendly and concise.\",\n  \"input\": [\n    {\n      \"role\": \"user\",\n      \"text\": \"Where should I get pizza near Union Square?\"\n    }\n  ],\n  \"voice_id\": \"sabrina\",\n  \"default_language\": \"en\",\n  \"additional_languages\": [\n    \"es\"\n  ],\n  \"tool_definitions\": [\n    {\n      \"name\": \"search_pizza_shop_recs\",\n      \"description\": \"Search for pizza shop recommendations.\",\n      \"parameters\": {\n        \"type\": \"object\",\n        \"properties\": {\n          \"location\": {\n            \"type\": \"string\",\n            \"description\": \"The neighborhood to search in.\"\n          }\n        },\n        \"required\": [\n          \"location\"\n        ],\n        \"additionalProperties\": false\n      }\n    }\n  ],\n  \"model\": \"phonic-1\",\n  \"num_responses\": 2\n}")

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

```ruby Generate responses
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/responses")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Post.new(url)
request["Authorization"] = 'Bearer <apiKey>'
request["Content-Type"] = 'application/json'
request.body = "{\n  \"system_prompt\": \"You help callers find a pizza shop. Be friendly and concise.\",\n  \"input\": [\n    {\n      \"role\": \"user\",\n      \"text\": \"Where should I get pizza near Union Square?\"\n    }\n  ],\n  \"voice_id\": \"sabrina\",\n  \"default_language\": \"en\",\n  \"additional_languages\": [\n    \"es\"\n  ],\n  \"tool_definitions\": [\n    {\n      \"name\": \"search_pizza_shop_recs\",\n      \"description\": \"Search for pizza shop recommendations.\",\n      \"parameters\": {\n        \"type\": \"object\",\n        \"properties\": {\n          \"location\": {\n            \"type\": \"string\",\n            \"description\": \"The neighborhood to search in.\"\n          }\n        },\n        \"required\": [\n          \"location\"\n        ],\n        \"additionalProperties\": false\n      }\n    }\n  ],\n  \"model\": \"phonic-1\",\n  \"num_responses\": 2\n}"

response = http.request(request)
puts response.read_body
```

```java Generate responses
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.post("https://api.phonic.ai/v1/responses")
  .header("Authorization", "Bearer <apiKey>")
  .header("Content-Type", "application/json")
  .body("{\n  \"system_prompt\": \"You help callers find a pizza shop. Be friendly and concise.\",\n  \"input\": [\n    {\n      \"role\": \"user\",\n      \"text\": \"Where should I get pizza near Union Square?\"\n    }\n  ],\n  \"voice_id\": \"sabrina\",\n  \"default_language\": \"en\",\n  \"additional_languages\": [\n    \"es\"\n  ],\n  \"tool_definitions\": [\n    {\n      \"name\": \"search_pizza_shop_recs\",\n      \"description\": \"Search for pizza shop recommendations.\",\n      \"parameters\": {\n        \"type\": \"object\",\n        \"properties\": {\n          \"location\": {\n            \"type\": \"string\",\n            \"description\": \"The neighborhood to search in.\"\n          }\n        },\n        \"required\": [\n          \"location\"\n        ],\n        \"additionalProperties\": false\n      }\n    }\n  ],\n  \"model\": \"phonic-1\",\n  \"num_responses\": 2\n}")
  .asString();
```

```php Generate responses
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('POST', 'https://api.phonic.ai/v1/responses', [
  'body' => '{
  "system_prompt": "You help callers find a pizza shop. Be friendly and concise.",
  "input": [
    {
      "role": "user",
      "text": "Where should I get pizza near Union Square?"
    }
  ],
  "voice_id": "sabrina",
  "default_language": "en",
  "additional_languages": [
    "es"
  ],
  "tool_definitions": [
    {
      "name": "search_pizza_shop_recs",
      "description": "Search for pizza shop recommendations.",
      "parameters": {
        "type": "object",
        "properties": {
          "location": {
            "type": "string",
            "description": "The neighborhood to search in."
          }
        },
        "required": [
          "location"
        ],
        "additionalProperties": false
      }
    }
  ],
  "model": "phonic-1",
  "num_responses": 2
}',
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
    'Content-Type' => 'application/json',
  ],
]);

echo $response->getBody();
```

```csharp Generate responses
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/responses");
var request = new RestRequest(Method.POST);
request.AddHeader("Authorization", "Bearer <apiKey>");
request.AddHeader("Content-Type", "application/json");
request.AddParameter("application/json", "{\n  \"system_prompt\": \"You help callers find a pizza shop. Be friendly and concise.\",\n  \"input\": [\n    {\n      \"role\": \"user\",\n      \"text\": \"Where should I get pizza near Union Square?\"\n    }\n  ],\n  \"voice_id\": \"sabrina\",\n  \"default_language\": \"en\",\n  \"additional_languages\": [\n    \"es\"\n  ],\n  \"tool_definitions\": [\n    {\n      \"name\": \"search_pizza_shop_recs\",\n      \"description\": \"Search for pizza shop recommendations.\",\n      \"parameters\": {\n        \"type\": \"object\",\n        \"properties\": {\n          \"location\": {\n            \"type\": \"string\",\n            \"description\": \"The neighborhood to search in.\"\n          }\n        },\n        \"required\": [\n          \"location\"\n        ],\n        \"additionalProperties\": false\n      }\n    }\n  ],\n  \"model\": \"phonic-1\",\n  \"num_responses\": 2\n}", ParameterType.RequestBody);
IRestResponse response = client.Execute(request);
```

```swift Generate responses
import Foundation

let headers = [
  "Authorization": "Bearer <apiKey>",
  "Content-Type": "application/json"
]
let parameters = [
  "system_prompt": "You help callers find a pizza shop. Be friendly and concise.",
  "input": [
    [
      "role": "user",
      "text": "Where should I get pizza near Union Square?"
    ]
  ],
  "voice_id": "sabrina",
  "default_language": "en",
  "additional_languages": ["es"],
  "tool_definitions": [
    [
      "name": "search_pizza_shop_recs",
      "description": "Search for pizza shop recommendations.",
      "parameters": [
        "type": "object",
        "properties": ["location": [
            "type": "string",
            "description": "The neighborhood to search in."
          ]],
        "required": ["location"],
        "additionalProperties": false
      ]
    ]
  ],
  "model": "phonic-1",
  "num_responses": 2
] as [String : Any]

let postData = JSONSerialization.data(withJSONObject: parameters, options: [])

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/responses")! as URL,
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

### Generate a response that takes an action

**Request**

```json
{
  "system_prompt": "You route callers to the right team. Be friendly and concise.",
  "input": [
    {
      "role": "user",
      "text": "I have a problem with my bill."
    }
  ],
  "project": "main",
  "tools": [
    "transfer_to_support",
    {
      "type": "built_in",
      "name": "natural_conversation_ending",
      "tool_config": {
        "speech_before_tool_call": "required"
      }
    }
  ]
}
```

**Response**

```json
{
  "responses": [
    {
      "text": "Let me get you over to support.",
      "tool_calls": [],
      "action": {
        "type": "transfer_to_phone_number",
        "phone_number": "+15551234567",
        "detect_voicemail": false,
        "use_agent_phone_number": true,
        "keep_listening": true,
        "on_transfer_no_answer": "return_to_assistant"
      }
    }
  ]
}
```

**SDK Code**

```python Generate a response that takes an action
import requests

url = "https://api.phonic.ai/v1/responses"

payload = {
    "system_prompt": "You route callers to the right team. Be friendly and concise.",
    "input": [
        {
            "role": "user",
            "text": "I have a problem with my bill."
        }
    ],
    "project": "main",
    "tools": [
        "transfer_to_support",
        {
            "type": "built_in",
            "name": "natural_conversation_ending",
            "tool_config": { "speech_before_tool_call": "required" }
        }
    ]
}
headers = {
    "Authorization": "Bearer <apiKey>",
    "Content-Type": "application/json"
}

response = requests.post(url, json=payload, headers=headers)

print(response.json())
```

```javascript Generate a response that takes an action
const url = 'https://api.phonic.ai/v1/responses';
const options = {
  method: 'POST',
  headers: {Authorization: 'Bearer <apiKey>', 'Content-Type': 'application/json'},
  body: '{"system_prompt":"You route callers to the right team. Be friendly and concise.","input":[{"role":"user","text":"I have a problem with my bill."}],"project":"main","tools":["transfer_to_support",{"type":"built_in","name":"natural_conversation_ending","tool_config":{"speech_before_tool_call":"required"}}]}'
};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go Generate a response that takes an action
package main

import (
	"fmt"
	"strings"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/responses"

	payload := strings.NewReader("{\n  \"system_prompt\": \"You route callers to the right team. Be friendly and concise.\",\n  \"input\": [\n    {\n      \"role\": \"user\",\n      \"text\": \"I have a problem with my bill.\"\n    }\n  ],\n  \"project\": \"main\",\n  \"tools\": [\n    \"transfer_to_support\",\n    {\n      \"type\": \"built_in\",\n      \"name\": \"natural_conversation_ending\",\n      \"tool_config\": {\n        \"speech_before_tool_call\": \"required\"\n      }\n    }\n  ]\n}")

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

```ruby Generate a response that takes an action
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/responses")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Post.new(url)
request["Authorization"] = 'Bearer <apiKey>'
request["Content-Type"] = 'application/json'
request.body = "{\n  \"system_prompt\": \"You route callers to the right team. Be friendly and concise.\",\n  \"input\": [\n    {\n      \"role\": \"user\",\n      \"text\": \"I have a problem with my bill.\"\n    }\n  ],\n  \"project\": \"main\",\n  \"tools\": [\n    \"transfer_to_support\",\n    {\n      \"type\": \"built_in\",\n      \"name\": \"natural_conversation_ending\",\n      \"tool_config\": {\n        \"speech_before_tool_call\": \"required\"\n      }\n    }\n  ]\n}"

response = http.request(request)
puts response.read_body
```

```java Generate a response that takes an action
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.post("https://api.phonic.ai/v1/responses")
  .header("Authorization", "Bearer <apiKey>")
  .header("Content-Type", "application/json")
  .body("{\n  \"system_prompt\": \"You route callers to the right team. Be friendly and concise.\",\n  \"input\": [\n    {\n      \"role\": \"user\",\n      \"text\": \"I have a problem with my bill.\"\n    }\n  ],\n  \"project\": \"main\",\n  \"tools\": [\n    \"transfer_to_support\",\n    {\n      \"type\": \"built_in\",\n      \"name\": \"natural_conversation_ending\",\n      \"tool_config\": {\n        \"speech_before_tool_call\": \"required\"\n      }\n    }\n  ]\n}")
  .asString();
```

```php Generate a response that takes an action
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('POST', 'https://api.phonic.ai/v1/responses', [
  'body' => '{
  "system_prompt": "You route callers to the right team. Be friendly and concise.",
  "input": [
    {
      "role": "user",
      "text": "I have a problem with my bill."
    }
  ],
  "project": "main",
  "tools": [
    "transfer_to_support",
    {
      "type": "built_in",
      "name": "natural_conversation_ending",
      "tool_config": {
        "speech_before_tool_call": "required"
      }
    }
  ]
}',
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
    'Content-Type' => 'application/json',
  ],
]);

echo $response->getBody();
```

```csharp Generate a response that takes an action
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/responses");
var request = new RestRequest(Method.POST);
request.AddHeader("Authorization", "Bearer <apiKey>");
request.AddHeader("Content-Type", "application/json");
request.AddParameter("application/json", "{\n  \"system_prompt\": \"You route callers to the right team. Be friendly and concise.\",\n  \"input\": [\n    {\n      \"role\": \"user\",\n      \"text\": \"I have a problem with my bill.\"\n    }\n  ],\n  \"project\": \"main\",\n  \"tools\": [\n    \"transfer_to_support\",\n    {\n      \"type\": \"built_in\",\n      \"name\": \"natural_conversation_ending\",\n      \"tool_config\": {\n        \"speech_before_tool_call\": \"required\"\n      }\n    }\n  ]\n}", ParameterType.RequestBody);
IRestResponse response = client.Execute(request);
```

```swift Generate a response that takes an action
import Foundation

let headers = [
  "Authorization": "Bearer <apiKey>",
  "Content-Type": "application/json"
]
let parameters = [
  "system_prompt": "You route callers to the right team. Be friendly and concise.",
  "input": [
    [
      "role": "user",
      "text": "I have a problem with my bill."
    ]
  ],
  "project": "main",
  "tools": [
    "transfer_to_support",
    [
      "type": "built_in",
      "name": "natural_conversation_ending",
      "tool_config": ["speech_before_tool_call": "required"]
    ]
  ]
] as [String : Any]

let postData = JSONSerialization.data(withJSONObject: parameters, options: [])

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/responses")! as URL,
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