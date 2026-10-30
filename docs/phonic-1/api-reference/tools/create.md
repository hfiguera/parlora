> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Create

POST https://api.phonic.ai/v1/tools
Content-Type: application/json

Creates a new tool in a project.

Reference: https://docs.phonic.ai/api-reference/tools/create

## Authentication

- `Authorization` header (bearer token, required) — Bearer authentication header of the form `Bearer <PHONIC_API_KEY>`. Manage your API keys [here](https://phonic.co/api-keys).

## Request

### Query parameters

- `project` (string, optional, default: main) — The name of the project to create the tool in.

### Body (application/json)

This endpoint expects a CreateToolRequest.

- `name` (string, required) — The name of the tool. Must be snake_case and unique within the organization.
- `description` (string, required) — A description of what the tool does.
- `type` (enum, required) — The type of tool.
  - Allowed values: `custom_context`, `custom_webhook`, `custom_websocket`, `built_in_transfer_to_phone_number`, `built_in_transfer_to_agent`, `built_in_natural_conversation_ending`, `built_in_keypad_input`, `built_in_choose_not_to_respond`
- `execution_mode` (enum, required) — Mode of operation.
  - Allowed values: `sync`, `async`
- `parameters` (CreateToolRequestParameters, optional, default: []) — The tool's parameters, either as a flat array of parameter definitions or as a raw JSON Schema object (use the object form for nested parameters). When sending an array: - For `custom_webhook` tools with POST method, each parameter must include a `location` field. - For `custom_webhook` tools with GET method, `location` defaults to `"query_string"` if not specified. - For `custom_websocket`, `built_in_transfer_to_phone_number`, and `built_in_transfer_to_agent` tools, `location` must not be specified. - `parameter_locations` must not be sent, since placement is carried inline on each parameter. When sending a JSON Schema object, `custom_webhook` tools supply parameter placement in `parameter_locations` instead. Tools that cannot have parameters (`custom_context` and the `built_in_*` types) must send an empty array or omit the field.
- `parameter_locations` (map from string to enum, optional) — Where each top-level parameter is sent in the webhook request, as a map from parameter name to location. Only for `custom_webhook` tools whose `parameters` are a raw JSON Schema object. Every key must name a top-level parameter. For POST webhooks, every parameter needs an entry. For GET webhooks, entries default to `"query_string"` and `"request_body"` is not allowed.
  - Allowed values: `request_body`, `query_string`, `url_path`
- `endpoint_method` (enum, optional) — Required for webhook tools. HTTP method for the webhook endpoint.
  - Allowed values: `GET`, `POST`
- `endpoint_url` (string, optional) — Required for webhook tools. Must be a publicly routable HTTPS URL without embedded credentials. May contain `{name}` placeholders in the path or query (not the scheme, host, port, or credentials), each filled by a required parameter with location `"url_path"`.
- `endpoint_headers` (map from string to string, optional) — Optional headers for webhook tools.
- `endpoint_timeout_ms` (integer, optional, default: 5000) — Timeout for webhook tools.
- `tool_call_output_timeout_ms` (integer, optional, default: 5000) — Timeout for WebSocket tool responses.
- `phone_number` (string, optional, nullable) — The E.164 formatted phone number to transfer calls to. Set to null if the agent should determine the phone number.
- `sip` (TransferSip, optional, nullable) — A SIP destination to transfer calls to instead of a phone number. Cannot be set together with phone_number, so phone_number must be null when sip is set. Only available for built_in_transfer_to_phone_number tools.
- `dtmf` (string, optional, nullable) — DTMF digits to send after the transfer connects (e.g., "1234"). Defaults to null. Ignored when dynamic_dtmf is true.
- `post_transfer_message` (string, optional, nullable) — Fixed line the agent speaks into the bridged call once the transfer connects. Defaults to null, meaning no announcement. Must be null when keep_listening is false, since Phonic drops out of the call and has no line to speak it on. Only available for built_in_transfer_to_phone_number tools.
- `dynamic_dtmf` (boolean, optional, default: false) — When true, the agent determines the DTMF digits at call time (and may choose to send none); the static dtmf is ignored.
- `use_agent_phone_number` (boolean, optional, default: true) — When true, Phonic will transfer the call using the agent's phone number. When false, Phonic will transfer the call using the phone number of the party to whom the agent is connected. This is only available for built_in_transfer_to_phone_number tools.
- `detect_voicemail` (boolean, optional, default: false) — When true, Phonic will listen in and tell the user if the transfer hits voicemail. This is only available for built_in_transfer_to_phone_number tools when use_agent_phone_number is true.
- `keep_listening` (boolean, optional) — When true, Phonic bridges the transfer and stays on the call. When false, Phonic drops out once the transfer connects, which requires use_agent_phone_number and detect_voicemail to be false and post_transfer_message to be null. Without DTMF the call is handed off with a SIP REFER; with DTMF (static or dynamic) Phonic bridges the call to send the digits and then detaches, leaving the two parties connected. Only available for built_in_transfer_to_phone_number tools. Defaults to the value of use_agent_phone_number.
- `on_transfer_no_answer` (enum, optional, default: return_to_assistant) — What happens when the transfer target does not answer before the ring timeout. `return_to_assistant` hands control back to the agent. `keep_retrying` keeps the caller on the line and re-dials the target until it answers, the caller hangs up, or a retry cap is reached, then returns to the assistant. `keep_retrying` only applies to bridged transfers, so it cannot be used when keep_listening is false. Only available for built_in_transfer_to_phone_number tools.
  - Allowed values: `return_to_assistant`, `keep_retrying`
- `agents_to_transfer_to` (list of string, optional) — Array of agent names that the LLM can choose from when transferring. Required for built_in_transfer_to_agent tools. All agents must exist in the same project as the tool.
- `require_speech_before_tool_call` (boolean, optional, default: false) — When true, forces the agent to speak before executing the tool.
- `speech_before_tool_call` (enum, optional) — For built_in_natural_conversation_ending and built_in_keypad_input tools. Whether the agent must speak before calling the tool ("required"), the model decides ("optional"), or the agent must stay silent ("suppressed"). Not used by other tool types.
  - Allowed values: `required`, `optional`, `suppressed`
- `respond_after_sec` (double, optional, nullable) — For built_in_choose_not_to_respond tools. Number of seconds to wait after the tool fires before the agent speaks a follow-up if the user stays silent. When null, the agent stays silent (default). Not used by other tool types.
- `wait_for_speech_before_tool_call` (boolean, optional, default: false) — If true, the agent will wait to finish speaking before executing the tool. This is only available for custom_webhook and custom_websocket tools.
- `forbid_speech_after_tool_call` (boolean, optional, default: false) — When true, forbids the agent from speaking after executing the tool. Available for custom_context, custom_webhook and custom_websocket tools.
- `forbid_tool_call_after_speech` (boolean, optional, default: false) — When true, forbids the agent from calling the tool right after it has spoken. Available for custom_webhook and custom_websocket tools.
- `allow_tool_chaining` (boolean, optional, default: true) — When true, allows the agent to chain and execute other tools after executing the tool. Available for custom_context, custom_webhook and custom_websocket tools.
- `wait_for_response` (boolean, optional, default: false) — The agent doesn't typically wait for the response of async tools. When true, makes the agent wait for a response, not call other tools and inform the user of the result. Only available for async custom_webhook and custom_websocket tools, and cannot be combined with allow_tool_chaining set to true.
- `uninterruptible` (boolean, optional) — When true, caller speech cannot interrupt the assistant while the tool call is running. Available for sync custom_webhook, sync custom_websocket, and built_in_transfer_to_phone_number tools. Defaults to true for phone transfers and false for custom tools. Prevents caller interruptions during the transfer, including the preceding announcement once protection is active.
- `can_run_during_user_speech` (boolean, optional, default: false) — When true, the agent can call the tool while the user is still speaking. Only available for custom_webhook, custom_websocket, and custom_context tools. Setting it to true requires the feature to be enabled for your organization; contact Phonic to get access.
- `context` (string, optional) — The static context returned to the agent. Required for custom_context tools.

## Response

### 201

Success response

- `id` (string, required) — The ID of the created tool.
- `name` (string, required) — The name of the created tool.

## Errors

### 400 Bad Request Error

Invalid parameters

- `Error`
  - BasicError: BasicError
  - ValidationError: ValidationError

### 403 Forbidden Error

Agent authentication cannot create tools

- `Error`
  - BasicError: BasicError
  - ValidationError: ValidationError

### 409 Conflict Error

Tool name already exists

- `Error`
  - BasicError: BasicError
  - ValidationError: ValidationError

## Types

### CreateToolRequestParameters

The tool's parameters, either as a flat array of parameter definitions or as a raw JSON Schema object (use the object form for nested parameters). When sending an array: - For `custom_webhook` tools with POST method, each parameter must include a `location` field. - For `custom_webhook` tools with GET method, `location` defaults to `"query_string"` if not specified. - For `custom_websocket`, `built_in_transfer_to_phone_number`, and `built_in_transfer_to_agent` tools, `location` must not be specified. - `parameter_locations` must not be sent, since placement is carried inline on each parameter. When sending a JSON Schema object, `custom_webhook` tools supply parameter placement in `parameter_locations` instead. Tools that cannot have parameters (`custom_context` and the `built_in_*` types) must send an empty array or omit the field.

- list of ToolParameter
- ToolParametersJsonSchema: ToolParametersJsonSchema

### TransferSip

A SIP destination to transfer calls to, used instead of a phone number.

- `uri` (string, required) — The SIP URI to transfer calls to, in the form `sip:user@host[:port][;transport=udp|tcp|tls]` or `sips:user@host[:port]`. `transport` is the only URI parameter allowed.
- `headers` (map from string to string, optional, default: {}) — Custom SIP headers to send with the transfer. Header names must start with `X-`, and values cannot contain line breaks. Headers require a bridged transfer (keep_listening true, or DTMF set), since a SIP REFER transfer can't carry them.

### BasicError

- `error` (BasicErrorError, optional)

### ValidationError

- `error` (ValidationErrorError, required)
- `param_errors` (map from string to string, required) — Parameter-specific validation errors

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

### BasicErrorError

- `message` (string, required) — Error message
- `code` (string, optional) — Error code

### ValidationErrorError

- `message` (string, required) — Error message

## Examples

### Created tool response

**Response**

```json
{
  "id": "tool_12cf6e88-c254-4d3e-a149-ddf1bdd2254c",
  "name": "book_appointment"
}
```

**SDK Code**

```python Created tool response
import requests

url = "https://api.phonic.ai/v1/tools"

querystring = {"project":"main"}

headers = {"Authorization": "Bearer <apiKey>"}

response = requests.post(url, headers=headers, params=querystring)

print(response.json())
```

```javascript Created tool response
const url = 'https://api.phonic.ai/v1/tools?project=main';
const options = {method: 'POST', headers: {Authorization: 'Bearer <apiKey>'}};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go Created tool response
package main

import (
	"fmt"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/tools?project=main"

	req, _ := http.NewRequest("POST", url, nil)

	req.Header.Add("Authorization", "Bearer <apiKey>")

	res, _ := http.DefaultClient.Do(req)

	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)

	fmt.Println(res)
	fmt.Println(string(body))

}
```

```ruby Created tool response
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/tools?project=main")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Post.new(url)
request["Authorization"] = 'Bearer <apiKey>'

response = http.request(request)
puts response.read_body
```

```java Created tool response
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.post("https://api.phonic.ai/v1/tools?project=main")
  .header("Authorization", "Bearer <apiKey>")
  .asString();
```

```php Created tool response
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('POST', 'https://api.phonic.ai/v1/tools?project=main', [
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
  ],
]);

echo $response->getBody();
```

```csharp Created tool response
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/tools?project=main");
var request = new RestRequest(Method.POST);
request.AddHeader("Authorization", "Bearer <apiKey>");
IRestResponse response = client.Execute(request);
```

```swift Created tool response
import Foundation

let headers = ["Authorization": "Bearer <apiKey>"]

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/tools?project=main")! as URL,
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

### Context tool example

**Request**

```json
{
  "name": "context_printer",
  "description": "Gets the specific context for fixing our printer",
  "type": "custom_context",
  "execution_mode": "sync",
  "parameters": [],
  "require_speech_before_tool_call": false,
  "forbid_speech_after_tool_call": false,
  "allow_tool_chaining": true,
  "context": "Press the A button 5 times then gently shake the printer."
}
```

**Response**

```json
{
  "id": "tool_12cf6e88-c254-4d3e-a149-ddf1bdd2254c",
  "name": "book_appointment"
}
```

**SDK Code**

```python Context tool example
import requests

url = "https://api.phonic.ai/v1/tools"

querystring = {"project":"main"}

payload = {
    "name": "context_printer",
    "description": "Gets the specific context for fixing our printer",
    "type": "custom_context",
    "execution_mode": "sync",
    "parameters": [],
    "require_speech_before_tool_call": False,
    "forbid_speech_after_tool_call": False,
    "allow_tool_chaining": True,
    "context": "Press the A button 5 times then gently shake the printer."
}
headers = {
    "Authorization": "Bearer <apiKey>",
    "Content-Type": "application/json"
}

response = requests.post(url, json=payload, headers=headers, params=querystring)

print(response.json())
```

```javascript Context tool example
const url = 'https://api.phonic.ai/v1/tools?project=main';
const options = {
  method: 'POST',
  headers: {Authorization: 'Bearer <apiKey>', 'Content-Type': 'application/json'},
  body: '{"name":"context_printer","description":"Gets the specific context for fixing our printer","type":"custom_context","execution_mode":"sync","parameters":[],"require_speech_before_tool_call":false,"forbid_speech_after_tool_call":false,"allow_tool_chaining":true,"context":"Press the A button 5 times then gently shake the printer."}'
};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go Context tool example
package main

import (
	"fmt"
	"strings"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/tools?project=main"

	payload := strings.NewReader("{\n  \"name\": \"context_printer\",\n  \"description\": \"Gets the specific context for fixing our printer\",\n  \"type\": \"custom_context\",\n  \"execution_mode\": \"sync\",\n  \"parameters\": [],\n  \"require_speech_before_tool_call\": false,\n  \"forbid_speech_after_tool_call\": false,\n  \"allow_tool_chaining\": true,\n  \"context\": \"Press the A button 5 times then gently shake the printer.\"\n}")

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

```ruby Context tool example
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/tools?project=main")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Post.new(url)
request["Authorization"] = 'Bearer <apiKey>'
request["Content-Type"] = 'application/json'
request.body = "{\n  \"name\": \"context_printer\",\n  \"description\": \"Gets the specific context for fixing our printer\",\n  \"type\": \"custom_context\",\n  \"execution_mode\": \"sync\",\n  \"parameters\": [],\n  \"require_speech_before_tool_call\": false,\n  \"forbid_speech_after_tool_call\": false,\n  \"allow_tool_chaining\": true,\n  \"context\": \"Press the A button 5 times then gently shake the printer.\"\n}"

response = http.request(request)
puts response.read_body
```

```java Context tool example
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.post("https://api.phonic.ai/v1/tools?project=main")
  .header("Authorization", "Bearer <apiKey>")
  .header("Content-Type", "application/json")
  .body("{\n  \"name\": \"context_printer\",\n  \"description\": \"Gets the specific context for fixing our printer\",\n  \"type\": \"custom_context\",\n  \"execution_mode\": \"sync\",\n  \"parameters\": [],\n  \"require_speech_before_tool_call\": false,\n  \"forbid_speech_after_tool_call\": false,\n  \"allow_tool_chaining\": true,\n  \"context\": \"Press the A button 5 times then gently shake the printer.\"\n}")
  .asString();
```

```php Context tool example
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('POST', 'https://api.phonic.ai/v1/tools?project=main', [
  'body' => '{
  "name": "context_printer",
  "description": "Gets the specific context for fixing our printer",
  "type": "custom_context",
  "execution_mode": "sync",
  "parameters": [],
  "require_speech_before_tool_call": false,
  "forbid_speech_after_tool_call": false,
  "allow_tool_chaining": true,
  "context": "Press the A button 5 times then gently shake the printer."
}',
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
    'Content-Type' => 'application/json',
  ],
]);

echo $response->getBody();
```

```csharp Context tool example
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/tools?project=main");
var request = new RestRequest(Method.POST);
request.AddHeader("Authorization", "Bearer <apiKey>");
request.AddHeader("Content-Type", "application/json");
request.AddParameter("application/json", "{\n  \"name\": \"context_printer\",\n  \"description\": \"Gets the specific context for fixing our printer\",\n  \"type\": \"custom_context\",\n  \"execution_mode\": \"sync\",\n  \"parameters\": [],\n  \"require_speech_before_tool_call\": false,\n  \"forbid_speech_after_tool_call\": false,\n  \"allow_tool_chaining\": true,\n  \"context\": \"Press the A button 5 times then gently shake the printer.\"\n}", ParameterType.RequestBody);
IRestResponse response = client.Execute(request);
```

```swift Context tool example
import Foundation

let headers = [
  "Authorization": "Bearer <apiKey>",
  "Content-Type": "application/json"
]
let parameters = [
  "name": "context_printer",
  "description": "Gets the specific context for fixing our printer",
  "type": "custom_context",
  "execution_mode": "sync",
  "parameters": [],
  "require_speech_before_tool_call": false,
  "forbid_speech_after_tool_call": false,
  "allow_tool_chaining": true,
  "context": "Press the A button 5 times then gently shake the printer."
] as [String : Any]

let postData = JSONSerialization.data(withJSONObject: parameters, options: [])

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/tools?project=main")! as URL,
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

### Webhook tool example

**Request**

```json
{
  "name": "book_appointment",
  "description": "Books an appointment in the calendar system",
  "type": "custom_webhook",
  "execution_mode": "sync",
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
}
```

**Response**

```json
{
  "id": "tool_12cf6e88-c254-4d3e-a149-ddf1bdd2254c",
  "name": "book_appointment"
}
```

**SDK Code**

```python Webhook tool example
import requests

url = "https://api.phonic.ai/v1/tools"

querystring = {"project":"main"}

payload = {
    "name": "book_appointment",
    "description": "Books an appointment in the calendar system",
    "type": "custom_webhook",
    "execution_mode": "sync",
    "parameters": [
        {
            "type": "string",
            "name": "date",
            "description": "The date for the appointment in YYYY-MM-DD format",
            "is_required": True,
            "location": "request_body"
        },
        {
            "type": "string",
            "name": "time",
            "description": "The time for the appointment in HH:MM format",
            "is_required": True,
            "location": "request_body"
        }
    ],
    "endpoint_method": "POST",
    "endpoint_url": "https://api.example.com/book-appointment",
    "endpoint_headers": {
        "Authorization": "Bearer token123",
        "Content-Type": "application/json"
    },
    "endpoint_timeout_ms": 5000,
    "require_speech_before_tool_call": False,
    "wait_for_speech_before_tool_call": False,
    "forbid_speech_after_tool_call": False,
    "allow_tool_chaining": True
}
headers = {
    "Authorization": "Bearer <apiKey>",
    "Content-Type": "application/json"
}

response = requests.post(url, json=payload, headers=headers, params=querystring)

print(response.json())
```

```javascript Webhook tool example
const url = 'https://api.phonic.ai/v1/tools?project=main';
const options = {
  method: 'POST',
  headers: {Authorization: 'Bearer <apiKey>', 'Content-Type': 'application/json'},
  body: '{"name":"book_appointment","description":"Books an appointment in the calendar system","type":"custom_webhook","execution_mode":"sync","parameters":[{"type":"string","name":"date","description":"The date for the appointment in YYYY-MM-DD format","is_required":true,"location":"request_body"},{"type":"string","name":"time","description":"The time for the appointment in HH:MM format","is_required":true,"location":"request_body"}],"endpoint_method":"POST","endpoint_url":"https://api.example.com/book-appointment","endpoint_headers":{"Authorization":"Bearer token123","Content-Type":"application/json"},"endpoint_timeout_ms":5000,"require_speech_before_tool_call":false,"wait_for_speech_before_tool_call":false,"forbid_speech_after_tool_call":false,"allow_tool_chaining":true}'
};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go Webhook tool example
package main

import (
	"fmt"
	"strings"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/tools?project=main"

	payload := strings.NewReader("{\n  \"name\": \"book_appointment\",\n  \"description\": \"Books an appointment in the calendar system\",\n  \"type\": \"custom_webhook\",\n  \"execution_mode\": \"sync\",\n  \"parameters\": [\n    {\n      \"type\": \"string\",\n      \"name\": \"date\",\n      \"description\": \"The date for the appointment in YYYY-MM-DD format\",\n      \"is_required\": true,\n      \"location\": \"request_body\"\n    },\n    {\n      \"type\": \"string\",\n      \"name\": \"time\",\n      \"description\": \"The time for the appointment in HH:MM format\",\n      \"is_required\": true,\n      \"location\": \"request_body\"\n    }\n  ],\n  \"endpoint_method\": \"POST\",\n  \"endpoint_url\": \"https://api.example.com/book-appointment\",\n  \"endpoint_headers\": {\n    \"Authorization\": \"Bearer token123\",\n    \"Content-Type\": \"application/json\"\n  },\n  \"endpoint_timeout_ms\": 5000,\n  \"require_speech_before_tool_call\": false,\n  \"wait_for_speech_before_tool_call\": false,\n  \"forbid_speech_after_tool_call\": false,\n  \"allow_tool_chaining\": true\n}")

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

```ruby Webhook tool example
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/tools?project=main")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Post.new(url)
request["Authorization"] = 'Bearer <apiKey>'
request["Content-Type"] = 'application/json'
request.body = "{\n  \"name\": \"book_appointment\",\n  \"description\": \"Books an appointment in the calendar system\",\n  \"type\": \"custom_webhook\",\n  \"execution_mode\": \"sync\",\n  \"parameters\": [\n    {\n      \"type\": \"string\",\n      \"name\": \"date\",\n      \"description\": \"The date for the appointment in YYYY-MM-DD format\",\n      \"is_required\": true,\n      \"location\": \"request_body\"\n    },\n    {\n      \"type\": \"string\",\n      \"name\": \"time\",\n      \"description\": \"The time for the appointment in HH:MM format\",\n      \"is_required\": true,\n      \"location\": \"request_body\"\n    }\n  ],\n  \"endpoint_method\": \"POST\",\n  \"endpoint_url\": \"https://api.example.com/book-appointment\",\n  \"endpoint_headers\": {\n    \"Authorization\": \"Bearer token123\",\n    \"Content-Type\": \"application/json\"\n  },\n  \"endpoint_timeout_ms\": 5000,\n  \"require_speech_before_tool_call\": false,\n  \"wait_for_speech_before_tool_call\": false,\n  \"forbid_speech_after_tool_call\": false,\n  \"allow_tool_chaining\": true\n}"

response = http.request(request)
puts response.read_body
```

```java Webhook tool example
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.post("https://api.phonic.ai/v1/tools?project=main")
  .header("Authorization", "Bearer <apiKey>")
  .header("Content-Type", "application/json")
  .body("{\n  \"name\": \"book_appointment\",\n  \"description\": \"Books an appointment in the calendar system\",\n  \"type\": \"custom_webhook\",\n  \"execution_mode\": \"sync\",\n  \"parameters\": [\n    {\n      \"type\": \"string\",\n      \"name\": \"date\",\n      \"description\": \"The date for the appointment in YYYY-MM-DD format\",\n      \"is_required\": true,\n      \"location\": \"request_body\"\n    },\n    {\n      \"type\": \"string\",\n      \"name\": \"time\",\n      \"description\": \"The time for the appointment in HH:MM format\",\n      \"is_required\": true,\n      \"location\": \"request_body\"\n    }\n  ],\n  \"endpoint_method\": \"POST\",\n  \"endpoint_url\": \"https://api.example.com/book-appointment\",\n  \"endpoint_headers\": {\n    \"Authorization\": \"Bearer token123\",\n    \"Content-Type\": \"application/json\"\n  },\n  \"endpoint_timeout_ms\": 5000,\n  \"require_speech_before_tool_call\": false,\n  \"wait_for_speech_before_tool_call\": false,\n  \"forbid_speech_after_tool_call\": false,\n  \"allow_tool_chaining\": true\n}")
  .asString();
```

```php Webhook tool example
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('POST', 'https://api.phonic.ai/v1/tools?project=main', [
  'body' => '{
  "name": "book_appointment",
  "description": "Books an appointment in the calendar system",
  "type": "custom_webhook",
  "execution_mode": "sync",
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
}',
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
    'Content-Type' => 'application/json',
  ],
]);

echo $response->getBody();
```

```csharp Webhook tool example
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/tools?project=main");
var request = new RestRequest(Method.POST);
request.AddHeader("Authorization", "Bearer <apiKey>");
request.AddHeader("Content-Type", "application/json");
request.AddParameter("application/json", "{\n  \"name\": \"book_appointment\",\n  \"description\": \"Books an appointment in the calendar system\",\n  \"type\": \"custom_webhook\",\n  \"execution_mode\": \"sync\",\n  \"parameters\": [\n    {\n      \"type\": \"string\",\n      \"name\": \"date\",\n      \"description\": \"The date for the appointment in YYYY-MM-DD format\",\n      \"is_required\": true,\n      \"location\": \"request_body\"\n    },\n    {\n      \"type\": \"string\",\n      \"name\": \"time\",\n      \"description\": \"The time for the appointment in HH:MM format\",\n      \"is_required\": true,\n      \"location\": \"request_body\"\n    }\n  ],\n  \"endpoint_method\": \"POST\",\n  \"endpoint_url\": \"https://api.example.com/book-appointment\",\n  \"endpoint_headers\": {\n    \"Authorization\": \"Bearer token123\",\n    \"Content-Type\": \"application/json\"\n  },\n  \"endpoint_timeout_ms\": 5000,\n  \"require_speech_before_tool_call\": false,\n  \"wait_for_speech_before_tool_call\": false,\n  \"forbid_speech_after_tool_call\": false,\n  \"allow_tool_chaining\": true\n}", ParameterType.RequestBody);
IRestResponse response = client.Execute(request);
```

```swift Webhook tool example
import Foundation

let headers = [
  "Authorization": "Bearer <apiKey>",
  "Content-Type": "application/json"
]
let parameters = [
  "name": "book_appointment",
  "description": "Books an appointment in the calendar system",
  "type": "custom_webhook",
  "execution_mode": "sync",
  "parameters": [
    [
      "type": "string",
      "name": "date",
      "description": "The date for the appointment in YYYY-MM-DD format",
      "is_required": true,
      "location": "request_body"
    ],
    [
      "type": "string",
      "name": "time",
      "description": "The time for the appointment in HH:MM format",
      "is_required": true,
      "location": "request_body"
    ]
  ],
  "endpoint_method": "POST",
  "endpoint_url": "https://api.example.com/book-appointment",
  "endpoint_headers": [
    "Authorization": "Bearer token123",
    "Content-Type": "application/json"
  ],
  "endpoint_timeout_ms": 5000,
  "require_speech_before_tool_call": false,
  "wait_for_speech_before_tool_call": false,
  "forbid_speech_after_tool_call": false,
  "allow_tool_chaining": true
] as [String : Any]

let postData = JSONSerialization.data(withJSONObject: parameters, options: [])

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/tools?project=main")! as URL,
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

### Webhook tool with raw JSON Schema parameters

**Request**

```json
{
  "name": "create_order",
  "description": "Creates an order in the fulfillment system",
  "type": "custom_webhook",
  "execution_mode": "sync",
  "parameters": {
    "type": "object",
    "properties": {
      "customer": {
        "type": "object",
        "description": "The customer placing the order",
        "properties": {
          "name": {
            "type": "string",
            "description": "The customer's full name"
          },
          "tier": {
            "type": "string",
            "enum": [
              "free",
              "pro"
            ],
            "description": "The customer's subscription tier"
          }
        },
        "required": [
          "name"
        ]
      },
      "items": {
        "type": "array",
        "description": "The items being ordered",
        "items": {
          "type": "object",
          "properties": {
            "sku": {
              "type": "string",
              "description": "The item's SKU"
            },
            "quantity": {
              "type": "integer",
              "description": "How many of the item to order"
            }
          },
          "required": [
            "sku",
            "quantity"
          ]
        }
      }
    },
    "required": [
      "customer",
      "items"
    ],
    "additionalProperties": false
  },
  "parameter_locations": {
    "customer": "request_body",
    "items": "request_body"
  },
  "endpoint_method": "POST",
  "endpoint_url": "https://api.example.com/orders",
  "endpoint_timeout_ms": 5000
}
```

**Response**

```json
{
  "id": "tool_12cf6e88-c254-4d3e-a149-ddf1bdd2254c",
  "name": "book_appointment"
}
```

**SDK Code**

```python Webhook tool with raw JSON Schema parameters
import requests

url = "https://api.phonic.ai/v1/tools"

querystring = {"project":"main"}

payload = {
    "name": "create_order",
    "description": "Creates an order in the fulfillment system",
    "type": "custom_webhook",
    "execution_mode": "sync",
    "parameters": {
        "type": "object",
        "properties": {
            "customer": {
                "type": "object",
                "description": "The customer placing the order",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "The customer's full name"
                    },
                    "tier": {
                        "type": "string",
                        "enum": ["free", "pro"],
                        "description": "The customer's subscription tier"
                    }
                },
                "required": ["name"]
            },
            "items": {
                "type": "array",
                "description": "The items being ordered",
                "items": {
                    "type": "object",
                    "properties": {
                        "sku": {
                            "type": "string",
                            "description": "The item's SKU"
                        },
                        "quantity": {
                            "type": "integer",
                            "description": "How many of the item to order"
                        }
                    },
                    "required": ["sku", "quantity"]
                }
            }
        },
        "required": ["customer", "items"],
        "additionalProperties": False
    },
    "parameter_locations": {
        "customer": "request_body",
        "items": "request_body"
    },
    "endpoint_method": "POST",
    "endpoint_url": "https://api.example.com/orders",
    "endpoint_timeout_ms": 5000
}
headers = {
    "Authorization": "Bearer <apiKey>",
    "Content-Type": "application/json"
}

response = requests.post(url, json=payload, headers=headers, params=querystring)

print(response.json())
```

```javascript Webhook tool with raw JSON Schema parameters
const url = 'https://api.phonic.ai/v1/tools?project=main';
const options = {
  method: 'POST',
  headers: {Authorization: 'Bearer <apiKey>', 'Content-Type': 'application/json'},
  body: '{"name":"create_order","description":"Creates an order in the fulfillment system","type":"custom_webhook","execution_mode":"sync","parameters":{"type":"object","properties":{"customer":{"type":"object","description":"The customer placing the order","properties":{"name":{"type":"string","description":"The customer\'s full name"},"tier":{"type":"string","enum":["free","pro"],"description":"The customer\'s subscription tier"}},"required":["name"]},"items":{"type":"array","description":"The items being ordered","items":{"type":"object","properties":{"sku":{"type":"string","description":"The item\'s SKU"},"quantity":{"type":"integer","description":"How many of the item to order"}},"required":["sku","quantity"]}}},"required":["customer","items"],"additionalProperties":false},"parameter_locations":{"customer":"request_body","items":"request_body"},"endpoint_method":"POST","endpoint_url":"https://api.example.com/orders","endpoint_timeout_ms":5000}'
};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go Webhook tool with raw JSON Schema parameters
package main

import (
	"fmt"
	"strings"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/tools?project=main"

	payload := strings.NewReader("{\n  \"name\": \"create_order\",\n  \"description\": \"Creates an order in the fulfillment system\",\n  \"type\": \"custom_webhook\",\n  \"execution_mode\": \"sync\",\n  \"parameters\": {\n    \"type\": \"object\",\n    \"properties\": {\n      \"customer\": {\n        \"type\": \"object\",\n        \"description\": \"The customer placing the order\",\n        \"properties\": {\n          \"name\": {\n            \"type\": \"string\",\n            \"description\": \"The customer's full name\"\n          },\n          \"tier\": {\n            \"type\": \"string\",\n            \"enum\": [\n              \"free\",\n              \"pro\"\n            ],\n            \"description\": \"The customer's subscription tier\"\n          }\n        },\n        \"required\": [\n          \"name\"\n        ]\n      },\n      \"items\": {\n        \"type\": \"array\",\n        \"description\": \"The items being ordered\",\n        \"items\": {\n          \"type\": \"object\",\n          \"properties\": {\n            \"sku\": {\n              \"type\": \"string\",\n              \"description\": \"The item's SKU\"\n            },\n            \"quantity\": {\n              \"type\": \"integer\",\n              \"description\": \"How many of the item to order\"\n            }\n          },\n          \"required\": [\n            \"sku\",\n            \"quantity\"\n          ]\n        }\n      }\n    },\n    \"required\": [\n      \"customer\",\n      \"items\"\n    ],\n    \"additionalProperties\": false\n  },\n  \"parameter_locations\": {\n    \"customer\": \"request_body\",\n    \"items\": \"request_body\"\n  },\n  \"endpoint_method\": \"POST\",\n  \"endpoint_url\": \"https://api.example.com/orders\",\n  \"endpoint_timeout_ms\": 5000\n}")

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

```ruby Webhook tool with raw JSON Schema parameters
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/tools?project=main")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Post.new(url)
request["Authorization"] = 'Bearer <apiKey>'
request["Content-Type"] = 'application/json'
request.body = "{\n  \"name\": \"create_order\",\n  \"description\": \"Creates an order in the fulfillment system\",\n  \"type\": \"custom_webhook\",\n  \"execution_mode\": \"sync\",\n  \"parameters\": {\n    \"type\": \"object\",\n    \"properties\": {\n      \"customer\": {\n        \"type\": \"object\",\n        \"description\": \"The customer placing the order\",\n        \"properties\": {\n          \"name\": {\n            \"type\": \"string\",\n            \"description\": \"The customer's full name\"\n          },\n          \"tier\": {\n            \"type\": \"string\",\n            \"enum\": [\n              \"free\",\n              \"pro\"\n            ],\n            \"description\": \"The customer's subscription tier\"\n          }\n        },\n        \"required\": [\n          \"name\"\n        ]\n      },\n      \"items\": {\n        \"type\": \"array\",\n        \"description\": \"The items being ordered\",\n        \"items\": {\n          \"type\": \"object\",\n          \"properties\": {\n            \"sku\": {\n              \"type\": \"string\",\n              \"description\": \"The item's SKU\"\n            },\n            \"quantity\": {\n              \"type\": \"integer\",\n              \"description\": \"How many of the item to order\"\n            }\n          },\n          \"required\": [\n            \"sku\",\n            \"quantity\"\n          ]\n        }\n      }\n    },\n    \"required\": [\n      \"customer\",\n      \"items\"\n    ],\n    \"additionalProperties\": false\n  },\n  \"parameter_locations\": {\n    \"customer\": \"request_body\",\n    \"items\": \"request_body\"\n  },\n  \"endpoint_method\": \"POST\",\n  \"endpoint_url\": \"https://api.example.com/orders\",\n  \"endpoint_timeout_ms\": 5000\n}"

response = http.request(request)
puts response.read_body
```

```java Webhook tool with raw JSON Schema parameters
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.post("https://api.phonic.ai/v1/tools?project=main")
  .header("Authorization", "Bearer <apiKey>")
  .header("Content-Type", "application/json")
  .body("{\n  \"name\": \"create_order\",\n  \"description\": \"Creates an order in the fulfillment system\",\n  \"type\": \"custom_webhook\",\n  \"execution_mode\": \"sync\",\n  \"parameters\": {\n    \"type\": \"object\",\n    \"properties\": {\n      \"customer\": {\n        \"type\": \"object\",\n        \"description\": \"The customer placing the order\",\n        \"properties\": {\n          \"name\": {\n            \"type\": \"string\",\n            \"description\": \"The customer's full name\"\n          },\n          \"tier\": {\n            \"type\": \"string\",\n            \"enum\": [\n              \"free\",\n              \"pro\"\n            ],\n            \"description\": \"The customer's subscription tier\"\n          }\n        },\n        \"required\": [\n          \"name\"\n        ]\n      },\n      \"items\": {\n        \"type\": \"array\",\n        \"description\": \"The items being ordered\",\n        \"items\": {\n          \"type\": \"object\",\n          \"properties\": {\n            \"sku\": {\n              \"type\": \"string\",\n              \"description\": \"The item's SKU\"\n            },\n            \"quantity\": {\n              \"type\": \"integer\",\n              \"description\": \"How many of the item to order\"\n            }\n          },\n          \"required\": [\n            \"sku\",\n            \"quantity\"\n          ]\n        }\n      }\n    },\n    \"required\": [\n      \"customer\",\n      \"items\"\n    ],\n    \"additionalProperties\": false\n  },\n  \"parameter_locations\": {\n    \"customer\": \"request_body\",\n    \"items\": \"request_body\"\n  },\n  \"endpoint_method\": \"POST\",\n  \"endpoint_url\": \"https://api.example.com/orders\",\n  \"endpoint_timeout_ms\": 5000\n}")
  .asString();
```

```php Webhook tool with raw JSON Schema parameters
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('POST', 'https://api.phonic.ai/v1/tools?project=main', [
  'body' => '{
  "name": "create_order",
  "description": "Creates an order in the fulfillment system",
  "type": "custom_webhook",
  "execution_mode": "sync",
  "parameters": {
    "type": "object",
    "properties": {
      "customer": {
        "type": "object",
        "description": "The customer placing the order",
        "properties": {
          "name": {
            "type": "string",
            "description": "The customer\'s full name"
          },
          "tier": {
            "type": "string",
            "enum": [
              "free",
              "pro"
            ],
            "description": "The customer\'s subscription tier"
          }
        },
        "required": [
          "name"
        ]
      },
      "items": {
        "type": "array",
        "description": "The items being ordered",
        "items": {
          "type": "object",
          "properties": {
            "sku": {
              "type": "string",
              "description": "The item\'s SKU"
            },
            "quantity": {
              "type": "integer",
              "description": "How many of the item to order"
            }
          },
          "required": [
            "sku",
            "quantity"
          ]
        }
      }
    },
    "required": [
      "customer",
      "items"
    ],
    "additionalProperties": false
  },
  "parameter_locations": {
    "customer": "request_body",
    "items": "request_body"
  },
  "endpoint_method": "POST",
  "endpoint_url": "https://api.example.com/orders",
  "endpoint_timeout_ms": 5000
}',
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
    'Content-Type' => 'application/json',
  ],
]);

echo $response->getBody();
```

```csharp Webhook tool with raw JSON Schema parameters
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/tools?project=main");
var request = new RestRequest(Method.POST);
request.AddHeader("Authorization", "Bearer <apiKey>");
request.AddHeader("Content-Type", "application/json");
request.AddParameter("application/json", "{\n  \"name\": \"create_order\",\n  \"description\": \"Creates an order in the fulfillment system\",\n  \"type\": \"custom_webhook\",\n  \"execution_mode\": \"sync\",\n  \"parameters\": {\n    \"type\": \"object\",\n    \"properties\": {\n      \"customer\": {\n        \"type\": \"object\",\n        \"description\": \"The customer placing the order\",\n        \"properties\": {\n          \"name\": {\n            \"type\": \"string\",\n            \"description\": \"The customer's full name\"\n          },\n          \"tier\": {\n            \"type\": \"string\",\n            \"enum\": [\n              \"free\",\n              \"pro\"\n            ],\n            \"description\": \"The customer's subscription tier\"\n          }\n        },\n        \"required\": [\n          \"name\"\n        ]\n      },\n      \"items\": {\n        \"type\": \"array\",\n        \"description\": \"The items being ordered\",\n        \"items\": {\n          \"type\": \"object\",\n          \"properties\": {\n            \"sku\": {\n              \"type\": \"string\",\n              \"description\": \"The item's SKU\"\n            },\n            \"quantity\": {\n              \"type\": \"integer\",\n              \"description\": \"How many of the item to order\"\n            }\n          },\n          \"required\": [\n            \"sku\",\n            \"quantity\"\n          ]\n        }\n      }\n    },\n    \"required\": [\n      \"customer\",\n      \"items\"\n    ],\n    \"additionalProperties\": false\n  },\n  \"parameter_locations\": {\n    \"customer\": \"request_body\",\n    \"items\": \"request_body\"\n  },\n  \"endpoint_method\": \"POST\",\n  \"endpoint_url\": \"https://api.example.com/orders\",\n  \"endpoint_timeout_ms\": 5000\n}", ParameterType.RequestBody);
IRestResponse response = client.Execute(request);
```

```swift Webhook tool with raw JSON Schema parameters
import Foundation

let headers = [
  "Authorization": "Bearer <apiKey>",
  "Content-Type": "application/json"
]
let parameters = [
  "name": "create_order",
  "description": "Creates an order in the fulfillment system",
  "type": "custom_webhook",
  "execution_mode": "sync",
  "parameters": [
    "type": "object",
    "properties": [
      "customer": [
        "type": "object",
        "description": "The customer placing the order",
        "properties": [
          "name": [
            "type": "string",
            "description": "The customer's full name"
          ],
          "tier": [
            "type": "string",
            "enum": ["free", "pro"],
            "description": "The customer's subscription tier"
          ]
        ],
        "required": ["name"]
      ],
      "items": [
        "type": "array",
        "description": "The items being ordered",
        "items": [
          "type": "object",
          "properties": [
            "sku": [
              "type": "string",
              "description": "The item's SKU"
            ],
            "quantity": [
              "type": "integer",
              "description": "How many of the item to order"
            ]
          ],
          "required": ["sku", "quantity"]
        ]
      ]
    ],
    "required": ["customer", "items"],
    "additionalProperties": false
  ],
  "parameter_locations": [
    "customer": "request_body",
    "items": "request_body"
  ],
  "endpoint_method": "POST",
  "endpoint_url": "https://api.example.com/orders",
  "endpoint_timeout_ms": 5000
] as [String : Any]

let postData = JSONSerialization.data(withJSONObject: parameters, options: [])

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/tools?project=main")! as URL,
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

### WebSocket tool example

**Request**

```json
{
  "name": "check_inventory",
  "description": "Checks product inventory levels",
  "type": "custom_websocket",
  "execution_mode": "async",
  "parameters": [
    {
      "type": "string",
      "name": "product_id",
      "description": "The product ID to check",
      "is_required": true
    }
  ],
  "tool_call_output_timeout_ms": 5000,
  "require_speech_before_tool_call": false,
  "wait_for_speech_before_tool_call": false,
  "forbid_speech_after_tool_call": false,
  "allow_tool_chaining": true,
  "wait_for_response": false
}
```

**Response**

```json
{
  "id": "tool_12cf6e88-c254-4d3e-a149-ddf1bdd2254c",
  "name": "book_appointment"
}
```

**SDK Code**

```python WebSocket tool example
import requests

url = "https://api.phonic.ai/v1/tools"

querystring = {"project":"main"}

payload = {
    "name": "check_inventory",
    "description": "Checks product inventory levels",
    "type": "custom_websocket",
    "execution_mode": "async",
    "parameters": [
        {
            "type": "string",
            "name": "product_id",
            "description": "The product ID to check",
            "is_required": True
        }
    ],
    "tool_call_output_timeout_ms": 5000,
    "require_speech_before_tool_call": False,
    "wait_for_speech_before_tool_call": False,
    "forbid_speech_after_tool_call": False,
    "allow_tool_chaining": True,
    "wait_for_response": False
}
headers = {
    "Authorization": "Bearer <apiKey>",
    "Content-Type": "application/json"
}

response = requests.post(url, json=payload, headers=headers, params=querystring)

print(response.json())
```

```javascript WebSocket tool example
const url = 'https://api.phonic.ai/v1/tools?project=main';
const options = {
  method: 'POST',
  headers: {Authorization: 'Bearer <apiKey>', 'Content-Type': 'application/json'},
  body: '{"name":"check_inventory","description":"Checks product inventory levels","type":"custom_websocket","execution_mode":"async","parameters":[{"type":"string","name":"product_id","description":"The product ID to check","is_required":true}],"tool_call_output_timeout_ms":5000,"require_speech_before_tool_call":false,"wait_for_speech_before_tool_call":false,"forbid_speech_after_tool_call":false,"allow_tool_chaining":true,"wait_for_response":false}'
};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go WebSocket tool example
package main

import (
	"fmt"
	"strings"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/tools?project=main"

	payload := strings.NewReader("{\n  \"name\": \"check_inventory\",\n  \"description\": \"Checks product inventory levels\",\n  \"type\": \"custom_websocket\",\n  \"execution_mode\": \"async\",\n  \"parameters\": [\n    {\n      \"type\": \"string\",\n      \"name\": \"product_id\",\n      \"description\": \"The product ID to check\",\n      \"is_required\": true\n    }\n  ],\n  \"tool_call_output_timeout_ms\": 5000,\n  \"require_speech_before_tool_call\": false,\n  \"wait_for_speech_before_tool_call\": false,\n  \"forbid_speech_after_tool_call\": false,\n  \"allow_tool_chaining\": true,\n  \"wait_for_response\": false\n}")

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

```ruby WebSocket tool example
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/tools?project=main")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Post.new(url)
request["Authorization"] = 'Bearer <apiKey>'
request["Content-Type"] = 'application/json'
request.body = "{\n  \"name\": \"check_inventory\",\n  \"description\": \"Checks product inventory levels\",\n  \"type\": \"custom_websocket\",\n  \"execution_mode\": \"async\",\n  \"parameters\": [\n    {\n      \"type\": \"string\",\n      \"name\": \"product_id\",\n      \"description\": \"The product ID to check\",\n      \"is_required\": true\n    }\n  ],\n  \"tool_call_output_timeout_ms\": 5000,\n  \"require_speech_before_tool_call\": false,\n  \"wait_for_speech_before_tool_call\": false,\n  \"forbid_speech_after_tool_call\": false,\n  \"allow_tool_chaining\": true,\n  \"wait_for_response\": false\n}"

response = http.request(request)
puts response.read_body
```

```java WebSocket tool example
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.post("https://api.phonic.ai/v1/tools?project=main")
  .header("Authorization", "Bearer <apiKey>")
  .header("Content-Type", "application/json")
  .body("{\n  \"name\": \"check_inventory\",\n  \"description\": \"Checks product inventory levels\",\n  \"type\": \"custom_websocket\",\n  \"execution_mode\": \"async\",\n  \"parameters\": [\n    {\n      \"type\": \"string\",\n      \"name\": \"product_id\",\n      \"description\": \"The product ID to check\",\n      \"is_required\": true\n    }\n  ],\n  \"tool_call_output_timeout_ms\": 5000,\n  \"require_speech_before_tool_call\": false,\n  \"wait_for_speech_before_tool_call\": false,\n  \"forbid_speech_after_tool_call\": false,\n  \"allow_tool_chaining\": true,\n  \"wait_for_response\": false\n}")
  .asString();
```

```php WebSocket tool example
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('POST', 'https://api.phonic.ai/v1/tools?project=main', [
  'body' => '{
  "name": "check_inventory",
  "description": "Checks product inventory levels",
  "type": "custom_websocket",
  "execution_mode": "async",
  "parameters": [
    {
      "type": "string",
      "name": "product_id",
      "description": "The product ID to check",
      "is_required": true
    }
  ],
  "tool_call_output_timeout_ms": 5000,
  "require_speech_before_tool_call": false,
  "wait_for_speech_before_tool_call": false,
  "forbid_speech_after_tool_call": false,
  "allow_tool_chaining": true,
  "wait_for_response": false
}',
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
    'Content-Type' => 'application/json',
  ],
]);

echo $response->getBody();
```

```csharp WebSocket tool example
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/tools?project=main");
var request = new RestRequest(Method.POST);
request.AddHeader("Authorization", "Bearer <apiKey>");
request.AddHeader("Content-Type", "application/json");
request.AddParameter("application/json", "{\n  \"name\": \"check_inventory\",\n  \"description\": \"Checks product inventory levels\",\n  \"type\": \"custom_websocket\",\n  \"execution_mode\": \"async\",\n  \"parameters\": [\n    {\n      \"type\": \"string\",\n      \"name\": \"product_id\",\n      \"description\": \"The product ID to check\",\n      \"is_required\": true\n    }\n  ],\n  \"tool_call_output_timeout_ms\": 5000,\n  \"require_speech_before_tool_call\": false,\n  \"wait_for_speech_before_tool_call\": false,\n  \"forbid_speech_after_tool_call\": false,\n  \"allow_tool_chaining\": true,\n  \"wait_for_response\": false\n}", ParameterType.RequestBody);
IRestResponse response = client.Execute(request);
```

```swift WebSocket tool example
import Foundation

let headers = [
  "Authorization": "Bearer <apiKey>",
  "Content-Type": "application/json"
]
let parameters = [
  "name": "check_inventory",
  "description": "Checks product inventory levels",
  "type": "custom_websocket",
  "execution_mode": "async",
  "parameters": [
    [
      "type": "string",
      "name": "product_id",
      "description": "The product ID to check",
      "is_required": true
    ]
  ],
  "tool_call_output_timeout_ms": 5000,
  "require_speech_before_tool_call": false,
  "wait_for_speech_before_tool_call": false,
  "forbid_speech_after_tool_call": false,
  "allow_tool_chaining": true,
  "wait_for_response": false
] as [String : Any]

let postData = JSONSerialization.data(withJSONObject: parameters, options: [])

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/tools?project=main")! as URL,
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

### Transfer to phone number

**Request**

```json
{
  "name": "transfer_to_support",
  "description": "Transfers the caller to the support team",
  "type": "built_in_transfer_to_phone_number",
  "execution_mode": "sync",
  "phone_number": "+15551234567",
  "dtmf": "1234",
  "dynamic_dtmf": false,
  "use_agent_phone_number": true,
  "detect_voicemail": false,
  "require_speech_before_tool_call": false
}
```

**Response**

```json
{
  "id": "tool_12cf6e88-c254-4d3e-a149-ddf1bdd2254c",
  "name": "book_appointment"
}
```

**SDK Code**

```python Transfer to phone number
import requests

url = "https://api.phonic.ai/v1/tools"

querystring = {"project":"main"}

payload = {
    "name": "transfer_to_support",
    "description": "Transfers the caller to the support team",
    "type": "built_in_transfer_to_phone_number",
    "execution_mode": "sync",
    "phone_number": "+15551234567",
    "dtmf": "1234",
    "dynamic_dtmf": False,
    "use_agent_phone_number": True,
    "detect_voicemail": False,
    "require_speech_before_tool_call": False
}
headers = {
    "Authorization": "Bearer <apiKey>",
    "Content-Type": "application/json"
}

response = requests.post(url, json=payload, headers=headers, params=querystring)

print(response.json())
```

```javascript Transfer to phone number
const url = 'https://api.phonic.ai/v1/tools?project=main';
const options = {
  method: 'POST',
  headers: {Authorization: 'Bearer <apiKey>', 'Content-Type': 'application/json'},
  body: '{"name":"transfer_to_support","description":"Transfers the caller to the support team","type":"built_in_transfer_to_phone_number","execution_mode":"sync","phone_number":"+15551234567","dtmf":"1234","dynamic_dtmf":false,"use_agent_phone_number":true,"detect_voicemail":false,"require_speech_before_tool_call":false}'
};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go Transfer to phone number
package main

import (
	"fmt"
	"strings"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/tools?project=main"

	payload := strings.NewReader("{\n  \"name\": \"transfer_to_support\",\n  \"description\": \"Transfers the caller to the support team\",\n  \"type\": \"built_in_transfer_to_phone_number\",\n  \"execution_mode\": \"sync\",\n  \"phone_number\": \"+15551234567\",\n  \"dtmf\": \"1234\",\n  \"dynamic_dtmf\": false,\n  \"use_agent_phone_number\": true,\n  \"detect_voicemail\": false,\n  \"require_speech_before_tool_call\": false\n}")

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

```ruby Transfer to phone number
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/tools?project=main")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Post.new(url)
request["Authorization"] = 'Bearer <apiKey>'
request["Content-Type"] = 'application/json'
request.body = "{\n  \"name\": \"transfer_to_support\",\n  \"description\": \"Transfers the caller to the support team\",\n  \"type\": \"built_in_transfer_to_phone_number\",\n  \"execution_mode\": \"sync\",\n  \"phone_number\": \"+15551234567\",\n  \"dtmf\": \"1234\",\n  \"dynamic_dtmf\": false,\n  \"use_agent_phone_number\": true,\n  \"detect_voicemail\": false,\n  \"require_speech_before_tool_call\": false\n}"

response = http.request(request)
puts response.read_body
```

```java Transfer to phone number
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.post("https://api.phonic.ai/v1/tools?project=main")
  .header("Authorization", "Bearer <apiKey>")
  .header("Content-Type", "application/json")
  .body("{\n  \"name\": \"transfer_to_support\",\n  \"description\": \"Transfers the caller to the support team\",\n  \"type\": \"built_in_transfer_to_phone_number\",\n  \"execution_mode\": \"sync\",\n  \"phone_number\": \"+15551234567\",\n  \"dtmf\": \"1234\",\n  \"dynamic_dtmf\": false,\n  \"use_agent_phone_number\": true,\n  \"detect_voicemail\": false,\n  \"require_speech_before_tool_call\": false\n}")
  .asString();
```

```php Transfer to phone number
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('POST', 'https://api.phonic.ai/v1/tools?project=main', [
  'body' => '{
  "name": "transfer_to_support",
  "description": "Transfers the caller to the support team",
  "type": "built_in_transfer_to_phone_number",
  "execution_mode": "sync",
  "phone_number": "+15551234567",
  "dtmf": "1234",
  "dynamic_dtmf": false,
  "use_agent_phone_number": true,
  "detect_voicemail": false,
  "require_speech_before_tool_call": false
}',
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
    'Content-Type' => 'application/json',
  ],
]);

echo $response->getBody();
```

```csharp Transfer to phone number
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/tools?project=main");
var request = new RestRequest(Method.POST);
request.AddHeader("Authorization", "Bearer <apiKey>");
request.AddHeader("Content-Type", "application/json");
request.AddParameter("application/json", "{\n  \"name\": \"transfer_to_support\",\n  \"description\": \"Transfers the caller to the support team\",\n  \"type\": \"built_in_transfer_to_phone_number\",\n  \"execution_mode\": \"sync\",\n  \"phone_number\": \"+15551234567\",\n  \"dtmf\": \"1234\",\n  \"dynamic_dtmf\": false,\n  \"use_agent_phone_number\": true,\n  \"detect_voicemail\": false,\n  \"require_speech_before_tool_call\": false\n}", ParameterType.RequestBody);
IRestResponse response = client.Execute(request);
```

```swift Transfer to phone number
import Foundation

let headers = [
  "Authorization": "Bearer <apiKey>",
  "Content-Type": "application/json"
]
let parameters = [
  "name": "transfer_to_support",
  "description": "Transfers the caller to the support team",
  "type": "built_in_transfer_to_phone_number",
  "execution_mode": "sync",
  "phone_number": "+15551234567",
  "dtmf": "1234",
  "dynamic_dtmf": false,
  "use_agent_phone_number": true,
  "detect_voicemail": false,
  "require_speech_before_tool_call": false
] as [String : Any]

let postData = JSONSerialization.data(withJSONObject: parameters, options: [])

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/tools?project=main")! as URL,
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

### Transfer to agent

**Request**

```json
{
  "name": "transfer_to_specialist",
  "description": "Transfers the caller to a specialist agent",
  "type": "built_in_transfer_to_agent",
  "execution_mode": "sync",
  "agents_to_transfer_to": [
    "sales-agent",
    "support-agent",
    "technical-agent"
  ],
  "require_speech_before_tool_call": false
}
```

**Response**

```json
{
  "id": "tool_12cf6e88-c254-4d3e-a149-ddf1bdd2254c",
  "name": "book_appointment"
}
```

**SDK Code**

```python Transfer to agent
import requests

url = "https://api.phonic.ai/v1/tools"

querystring = {"project":"main"}

payload = {
    "name": "transfer_to_specialist",
    "description": "Transfers the caller to a specialist agent",
    "type": "built_in_transfer_to_agent",
    "execution_mode": "sync",
    "agents_to_transfer_to": ["sales-agent", "support-agent", "technical-agent"],
    "require_speech_before_tool_call": False
}
headers = {
    "Authorization": "Bearer <apiKey>",
    "Content-Type": "application/json"
}

response = requests.post(url, json=payload, headers=headers, params=querystring)

print(response.json())
```

```javascript Transfer to agent
const url = 'https://api.phonic.ai/v1/tools?project=main';
const options = {
  method: 'POST',
  headers: {Authorization: 'Bearer <apiKey>', 'Content-Type': 'application/json'},
  body: '{"name":"transfer_to_specialist","description":"Transfers the caller to a specialist agent","type":"built_in_transfer_to_agent","execution_mode":"sync","agents_to_transfer_to":["sales-agent","support-agent","technical-agent"],"require_speech_before_tool_call":false}'
};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go Transfer to agent
package main

import (
	"fmt"
	"strings"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/tools?project=main"

	payload := strings.NewReader("{\n  \"name\": \"transfer_to_specialist\",\n  \"description\": \"Transfers the caller to a specialist agent\",\n  \"type\": \"built_in_transfer_to_agent\",\n  \"execution_mode\": \"sync\",\n  \"agents_to_transfer_to\": [\n    \"sales-agent\",\n    \"support-agent\",\n    \"technical-agent\"\n  ],\n  \"require_speech_before_tool_call\": false\n}")

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

```ruby Transfer to agent
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/tools?project=main")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Post.new(url)
request["Authorization"] = 'Bearer <apiKey>'
request["Content-Type"] = 'application/json'
request.body = "{\n  \"name\": \"transfer_to_specialist\",\n  \"description\": \"Transfers the caller to a specialist agent\",\n  \"type\": \"built_in_transfer_to_agent\",\n  \"execution_mode\": \"sync\",\n  \"agents_to_transfer_to\": [\n    \"sales-agent\",\n    \"support-agent\",\n    \"technical-agent\"\n  ],\n  \"require_speech_before_tool_call\": false\n}"

response = http.request(request)
puts response.read_body
```

```java Transfer to agent
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.post("https://api.phonic.ai/v1/tools?project=main")
  .header("Authorization", "Bearer <apiKey>")
  .header("Content-Type", "application/json")
  .body("{\n  \"name\": \"transfer_to_specialist\",\n  \"description\": \"Transfers the caller to a specialist agent\",\n  \"type\": \"built_in_transfer_to_agent\",\n  \"execution_mode\": \"sync\",\n  \"agents_to_transfer_to\": [\n    \"sales-agent\",\n    \"support-agent\",\n    \"technical-agent\"\n  ],\n  \"require_speech_before_tool_call\": false\n}")
  .asString();
```

```php Transfer to agent
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('POST', 'https://api.phonic.ai/v1/tools?project=main', [
  'body' => '{
  "name": "transfer_to_specialist",
  "description": "Transfers the caller to a specialist agent",
  "type": "built_in_transfer_to_agent",
  "execution_mode": "sync",
  "agents_to_transfer_to": [
    "sales-agent",
    "support-agent",
    "technical-agent"
  ],
  "require_speech_before_tool_call": false
}',
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
    'Content-Type' => 'application/json',
  ],
]);

echo $response->getBody();
```

```csharp Transfer to agent
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/tools?project=main");
var request = new RestRequest(Method.POST);
request.AddHeader("Authorization", "Bearer <apiKey>");
request.AddHeader("Content-Type", "application/json");
request.AddParameter("application/json", "{\n  \"name\": \"transfer_to_specialist\",\n  \"description\": \"Transfers the caller to a specialist agent\",\n  \"type\": \"built_in_transfer_to_agent\",\n  \"execution_mode\": \"sync\",\n  \"agents_to_transfer_to\": [\n    \"sales-agent\",\n    \"support-agent\",\n    \"technical-agent\"\n  ],\n  \"require_speech_before_tool_call\": false\n}", ParameterType.RequestBody);
IRestResponse response = client.Execute(request);
```

```swift Transfer to agent
import Foundation

let headers = [
  "Authorization": "Bearer <apiKey>",
  "Content-Type": "application/json"
]
let parameters = [
  "name": "transfer_to_specialist",
  "description": "Transfers the caller to a specialist agent",
  "type": "built_in_transfer_to_agent",
  "execution_mode": "sync",
  "agents_to_transfer_to": ["sales-agent", "support-agent", "technical-agent"],
  "require_speech_before_tool_call": false
] as [String : Any]

let postData = JSONSerialization.data(withJSONObject: parameters, options: [])

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/tools?project=main")! as URL,
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