> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# List

GET https://api.phonic.ai/v1/tools

Returns all custom tools for the organization.

Reference: https://docs.phonic.ai/api-reference/tools/list

## Authentication

- `Authorization` header (bearer token, required) — Bearer authentication header of the form `Bearer <PHONIC_API_KEY>`. Manage your API keys [here](https://phonic.co/api-keys).

## Request

### Query parameters

- `project` (string, optional, default: main) — The name of the project to list tools for.

## Response

### 200

Success response

- `tools` (list of Tool, required)

## Errors

### 404 Not Found Error

Project not found

- `Error`
  - BasicError: BasicError
  - ValidationError: ValidationError

## Types

### Tool

- `id` (string, required) — The ID of the tool.
- `name` (string, required) — The name of the tool.
- `description` (string, required) — Description of what the tool does.
- `project` (ToolProject, required)
- `type` (enum, required) — The type of tool.
  - Allowed values: `custom_context`, `custom_webhook`, `custom_websocket`, `built_in_transfer_to_phone_number`, `built_in_transfer_to_agent`, `built_in_natural_conversation_ending`, `built_in_keypad_input`, `built_in_choose_not_to_respond`
- `parameters` (ToolParameters, required) — The tool's parameters, returned in the same form they were defined in. Tools defined with a flat list of parameters return an array of parameter definitions (with `location` included inline for `custom_webhook` tools). Tools defined with a raw JSON Schema object return that object; for `custom_webhook` tools the parameter placement is then returned separately in `parameter_locations`.
- `execution_mode` (enum, optional) — Mode of operation - sync waits for response, async continues without waiting.
  - Allowed values: `sync`, `async`
- `parameter_locations` (map from string to enum, optional) — Where each top-level parameter is sent in the webhook request, as a map from parameter name to location. Only returned for `custom_webhook` tools whose `parameters` are a raw JSON Schema object. Tools defined with a flat list of parameters carry `location` inline on each parameter instead.
  - Allowed values: `request_body`, `query_string`, `url_path`
- `endpoint_method` (enum, optional) — HTTP method for webhook tools.
  - Allowed values: `GET`, `POST`
- `endpoint_url` (string, optional) — URL for webhook tools.
- `endpoint_headers` (map from string to string, optional) — Headers for webhook tools.
- `endpoint_timeout_ms` (integer, optional) — Timeout in milliseconds for webhook tools.
- `tool_call_output_timeout_ms` (integer, optional) — Timeout in milliseconds for WebSocket tool responses.
- `phone_number` (string, optional, nullable) — The E.164 formatted phone number to transfer calls to. Set to null if the agent should determine the phone number.
- `sip` (TransferSip, optional, nullable) — The SIP destination to transfer calls to. Mutually exclusive with phone_number; null when transferring to a phone number. Only returned for built_in_transfer_to_phone_number tools.
- `dtmf` (string, optional, nullable) — DTMF digits to send after the transfer connects (e.g., "1234"). Defaults to null. Ignored when dynamic_dtmf is true.
- `post_transfer_message` (string, optional, nullable) — Fixed line the agent speaks into the bridged call once the transfer connects. Defaults to null, meaning no announcement. Always null when keep_listening is false. Only returned for built_in_transfer_to_phone_number tools.
- `dynamic_dtmf` (boolean, optional, default: false) — When true, the agent determines the DTMF digits at call time (and may choose to send none); the static dtmf is ignored.
- `use_agent_phone_number` (boolean, optional, default: true) — When true, Phonic will transfer the call using the agent's phone number. When false, Phonic will transfer the call using the phone number of the party to whom the agent is connected. This is only available for built_in_transfer_to_phone_number tools.
- `detect_voicemail` (boolean, optional, default: false) — When true, Phonic will listen in and tell the user if the transfer hits voicemail. This is only available for built_in_transfer_to_phone_number tools when use_agent_phone_number is true.
- `keep_listening` (boolean, optional, default: true) — When true, Phonic bridges the transfer and stays on the call. When false, Phonic drops out once the transfer connects, so use_agent_phone_number and detect_voicemail are false and post_transfer_message is null. Without DTMF the call is handed off with a SIP REFER; with DTMF (static or dynamic) Phonic bridges the call to send the digits and then detaches, leaving the two parties connected. Only returned for built_in_transfer_to_phone_number tools.
- `on_transfer_no_answer` (enum, optional, default: return_to_assistant) — What happens when the transfer target does not answer before the ring timeout. `return_to_assistant` hands control back to the agent. `keep_retrying` keeps the caller on the line and re-dials the target until it answers, the caller hangs up, or a retry cap is reached, then returns to the assistant. `keep_retrying` only applies to bridged transfers (keep_listening true). Only returned for built_in_transfer_to_phone_number tools.
  - Allowed values: `return_to_assistant`, `keep_retrying`
- `agents_to_transfer_to` (list of string, optional) — Array of agent names that the LLM can choose from when transferring. Required for built_in_transfer_to_agent tools.
- `require_speech_before_tool_call` (boolean, optional, default: false) — When true, forces the agent to speak before executing the tool.
- `speech_before_tool_call` (enum, optional) — For built_in_natural_conversation_ending and built_in_keypad_input tools. Whether the agent must speak before calling the tool ("required"), the model decides ("optional"), or the agent must stay silent ("suppressed"). Not used by other tool types.
  - Allowed values: `required`, `optional`, `suppressed`
- `respond_after_sec` (double, optional, nullable) — For built_in_choose_not_to_respond tools. Number of seconds to wait after the tool fires before the agent speaks a follow-up if the user stays silent. When null, the agent stays silent (default). Not used by other tool types.
- `wait_for_speech_before_tool_call` (boolean, optional, default: false) — If true, the agent will wait to finish speaking before executing the tool. This is only available for custom_webhook and custom_websocket tools.
- `forbid_speech_after_tool_call` (boolean, optional, default: false) — When true, forbids the agent from speaking after executing the tool. Available for custom_context, custom_webhook and custom_websocket tools.
- `forbid_tool_call_after_speech` (boolean, optional, default: false) — When true, forbids the agent from calling the tool right after it has spoken. Available for custom_webhook and custom_websocket tools.
- `allow_tool_chaining` (boolean, optional, default: true) — When true, allows the agent to chain and execute other tools after executing the tool. Available for custom_context, custom_webhook and custom_websocket tools.
- `wait_for_response` (boolean, optional, default: false) — The agent doesn't typically wait for the response of async tools. When true, makes the agent wait for a response, not call other tools and inform the user of the result. Only returned for custom_webhook and custom_websocket tools.
- `uninterruptible` (boolean, optional) — Whether caller speech is prevented from interrupting the assistant while the tool call is running. Returned for custom_webhook, custom_websocket, and built_in_transfer_to_phone_number tools. Phone transfers without a stored setting default to true.
- `can_run_during_user_speech` (boolean, optional, default: false) — When true, the agent can call the tool while the user is still speaking. Only returned for custom_webhook, custom_websocket, and custom_context tools.
- `context` (string, optional) — The static context returned to the agent. Only present for custom_context tools.

### BasicError

- `error` (BasicErrorError, optional)

### ValidationError

- `error` (ValidationErrorError, required)
- `param_errors` (map from string to string, required) — Parameter-specific validation errors

### ToolProject

- `id` (string, required)
- `name` (string, required)

### ToolParameters

The tool's parameters, returned in the same form they were defined in. Tools defined with a flat list of parameters return an array of parameter definitions (with `location` included inline for `custom_webhook` tools). Tools defined with a raw JSON Schema object return that object; for `custom_webhook` tools the parameter placement is then returned separately in `parameter_locations`.

- list of ToolParameter
- ToolParametersJsonSchema: ToolParametersJsonSchema

### TransferSip

A SIP destination to transfer calls to, used instead of a phone number.

- `uri` (string, required) — The SIP URI to transfer calls to, in the form `sip:user@host[:port][;transport=udp|tcp|tls]` or `sips:user@host[:port]`. `transport` is the only URI parameter allowed.
- `headers` (map from string to string, optional, default: {}) — Custom SIP headers to send with the transfer. Header names must start with `X-`, and values cannot contain line breaks. Headers require a bridged transfer (keep_listening true, or DTMF set), since a SIP REFER transfer can't carry them.

### BasicErrorError

- `message` (string, required) — Error message
- `code` (string, optional) — Error code

### ValidationErrorError

- `message` (string, required) — Error message

### ToolParameter

- `type` (enum, required) — The parameter type.
  - Allowed values: `string`, `integer`, `number`, `boolean`, `array`, `enum`
- `name` (string, required) — The parameter name.
- `description` (string, required) — Description of the parameter.
- `is_required` (boolean, required) — Whether the parameter is required.
- `item_type` (enum, optional) — Required only when type is "array". The type of items in the array.
  - Allowed values: `string`, `integer`, `number`, `boolean`
- `enum_values` (list of string, optional) — Required only when type is "enum". The fixed set of allowed string values for the parameter. Values must be unique and non-empty.
- `location` (enum, optional) — Only applicable for `custom_webhook` tools. Specifies where the parameter should be sent in the webhook request. * For GET webhooks: defaults to `"query_string"` and `"request_body"` is not allowed. * For POST webhooks: required, can be `"request_body"`, `"query_string"`, or `"url_path"`. * `"url_path"` fills a matching `{name}` placeholder in the endpoint URL's path or query (GET and POST). The parameter must be required, and every placeholder in `endpoint_url` must have a matching `url_path` parameter. * Not allowed for `custom_websocket`, `built_in_transfer_to_phone_number`, or `built_in_transfer_to_agent` tools. When switching a webhook tool's `endpoint_method` from POST to GET, its request body parameters must be re-sent with `"query_string"` locations.
  - Allowed values: `request_body`, `query_string`, `url_path`

### ToolParametersJsonSchema

A tool's parameters expressed as a raw JSON Schema object, for parameters that the flat `ToolParameter` list cannot express: nested objects, arrays of objects, `anyOf` variants, `null`, and non-string enums. Each entry in `properties` is a JSON Schema value supporting `type` (`"string"`, `"integer"`, `"number"`, `"boolean"`, `"null"`, `"array"`, `"object"`), `description`, `enum` (string parameters only), `items` (for arrays), `properties`/`required`/`additionalProperties` (for objects) and `anyOf`. Values may be nested up to 5 levels deep. Parameter names cannot be any of the reserved names that Phonic injects into every tool call: `call_info`, `conversation_id`, `from_phone_number`, `pre_tool_text`, `to_phone_number`, `twilio_call_sid`. For `custom_webhook` tools, parameter placement is supplied separately in `parameter_locations` rather than inline on the schema.

- `type` ("object", required)
- `properties` (map from string to any, required) — The tool's top-level parameters, as a map from parameter name to its JSON Schema.
- `required` (list of string, optional, default: []) — The names of the required top-level parameters. Every name must be defined in `properties`.
- `additionalProperties` (false, optional, default: false) — Must be `false`. Tool parameter schemas do not allow properties beyond the ones declared.

## Examples

**Response**

```json
{
  "tools": [
    {
      "id": "tool_29874283-c829-abf9-3028-309bc7aw3098",
      "name": "context_printer",
      "description": "Gets the specific context for fixing our printer",
      "project": {
        "id": "proj_8e5bdac5-868d-46fa-b300-439e777f7bfd",
        "name": "main"
      },
      "type": "custom_context",
      "parameters": [],
      "execution_mode": "sync",
      "require_speech_before_tool_call": false,
      "forbid_speech_after_tool_call": false,
      "allow_tool_chaining": true,
      "context": "Press the A button 5 times then gently shake the printer."
    },
    {
      "id": "tool_12cf6e88-c254-4d3e-a149-ddf1bdd2254c",
      "name": "book_appointment",
      "description": "Books an appointment in the calendar system",
      "project": {
        "id": "proj_8e5bdac5-868d-46fa-b300-439e777f7bfd",
        "name": "main"
      },
      "type": "custom_webhook",
      "parameters": [
        {
          "type": "string",
          "name": "date",
          "description": "The date for the appointment in YYYY-MM-DD format",
          "is_required": true,
          "location": "request_body"
        },
        {
          "type": "string",
          "name": "time",
          "description": "The time for the appointment in HH:MM format",
          "is_required": true,
          "location": "request_body"
        }
      ],
      "execution_mode": "sync",
      "endpoint_method": "POST",
      "endpoint_url": "https://api.example.com/book-appointment",
      "endpoint_headers": {
        "Authorization": "Bearer token123",
        "Content-Type": "application/json"
      },
      "endpoint_timeout_ms": 5000,
      "require_speech_before_tool_call": false,
      "wait_for_speech_before_tool_call": false,
      "forbid_speech_after_tool_call": false,
      "allow_tool_chaining": true
    },
    {
      "id": "tool_98765432-abcd-efgh-ijkl-mnopqrstuvwx",
      "name": "get_product_recommendations",
      "description": "Gets personalized product recommendations",
      "project": {
        "id": "proj_8e5bdac5-868d-46fa-b300-439e777f7bfd",
        "name": "main"
      },
      "type": "custom_websocket",
      "parameters": [
        {
          "type": "string",
          "name": "category",
          "description": "Product category (e.g., 'handbags', 'shoes', 'electronics')",
          "is_required": true
        }
      ],
      "execution_mode": "async",
      "tool_call_output_timeout_ms": 5000,
      "require_speech_before_tool_call": false,
      "wait_for_speech_before_tool_call": false,
      "forbid_speech_after_tool_call": false,
      "allow_tool_chaining": true,
      "wait_for_response": false
    },
    {
      "id": "tool_11111111-2222-3333-4444-555555555555",
      "name": "transfer_to_support",
      "description": "Transfers the caller to the support team",
      "project": {
        "id": "proj_8e5bdac5-868d-46fa-b300-439e777f7bfd",
        "name": "main"
      },
      "type": "built_in_transfer_to_phone_number",
      "parameters": [],
      "execution_mode": "sync",
      "phone_number": "+15551234567",
      "dtmf": "1234",
      "dynamic_dtmf": false,
      "use_agent_phone_number": true,
      "detect_voicemail": false,
      "keep_listening": true,
      "on_transfer_no_answer": "return_to_assistant",
      "require_speech_before_tool_call": false
    },
    {
      "id": "tool_22222222-3333-4444-5555-666666666666",
      "name": "transfer_to_specialist",
      "description": "Transfers the caller to a specialist agent",
      "project": {
        "id": "proj_8e5bdac5-868d-46fa-b300-439e777f7bfd",
        "name": "main"
      },
      "type": "built_in_transfer_to_agent",
      "parameters": [],
      "execution_mode": "sync",
      "agents_to_transfer_to": [
        "sales-agent",
        "support-agent",
        "technical-agent"
      ],
      "require_speech_before_tool_call": false
    }
  ]
}
```

**SDK Code**

```python List of tools
import requests

url = "https://api.phonic.ai/v1/tools"

querystring = {"project":"main"}

headers = {"Authorization": "Bearer <apiKey>"}

response = requests.get(url, headers=headers, params=querystring)

print(response.json())
```

```javascript List of tools
const url = 'https://api.phonic.ai/v1/tools?project=main';
const options = {method: 'GET', headers: {Authorization: 'Bearer <apiKey>'}};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go List of tools
package main

import (
	"fmt"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/tools?project=main"

	req, _ := http.NewRequest("GET", url, nil)

	req.Header.Add("Authorization", "Bearer <apiKey>")

	res, _ := http.DefaultClient.Do(req)

	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)

	fmt.Println(res)
	fmt.Println(string(body))

}
```

```ruby List of tools
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/tools?project=main")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Get.new(url)
request["Authorization"] = 'Bearer <apiKey>'

response = http.request(request)
puts response.read_body
```

```java List of tools
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.get("https://api.phonic.ai/v1/tools?project=main")
  .header("Authorization", "Bearer <apiKey>")
  .asString();
```

```php List of tools
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('GET', 'https://api.phonic.ai/v1/tools?project=main', [
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
  ],
]);

echo $response->getBody();
```

```csharp List of tools
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/tools?project=main");
var request = new RestRequest(Method.GET);
request.AddHeader("Authorization", "Bearer <apiKey>");
IRestResponse response = client.Execute(request);
```

```swift List of tools
import Foundation

let headers = ["Authorization": "Bearer <apiKey>"]

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/tools?project=main")! as URL,
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