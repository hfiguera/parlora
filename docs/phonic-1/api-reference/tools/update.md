> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Update

PATCH https://api.phonic.ai/v1/tools/{nameOrId}
Content-Type: application/json

Updates a tool by name or ID.

Reference: https://docs.phonic.ai/api-reference/tools/update

## Authentication

- `Authorization` header (bearer token, required) — Bearer authentication header of the form `Bearer <PHONIC_API_KEY>`. Manage your API keys [here](https://phonic.co/api-keys).

## Request

### Path parameters

- `nameOrId` (string, required) — The name or the ID of the tool to update.

### Query parameters

- `project` (string, optional, default: main) — The name of the project containing the tool. Only used when `nameOrId` is a name.

### Body (application/json)

This endpoint expects an UpdateToolRequest.

- `name` (string, optional) — The name of the tool. Must be snake_case and unique within the organization.
- `description` (string, optional) — A description of what the tool does.
- `execution_mode` (enum, optional) — Mode of operation.
  - Allowed values: `sync`, `async`
- `context` (string, optional) — The static context returned to the agent. Only applicable to custom_context tools.
- `parameters` (UpdateToolRequestParameters, optional) — The tool's parameters, either as a flat array of parameter definitions or as a raw JSON Schema object (use the object form for nested parameters). Replaces the tool's existing parameters, including the form they are stored in. For `custom_webhook` tools: when sending an array, `location` is required for POST and defaults to `"query_string"` for GET, and `parameter_locations` must not be sent; when sending a JSON Schema object, placement is supplied in `parameter_locations`. For `custom_websocket`, `built_in_transfer_to_phone_number`, and `built_in_transfer_to_agent` tools: `location` must not be specified.
- `parameter_locations` (map from string to enum, optional) — Where each top-level parameter is sent in the webhook request, as a map from parameter name to location. Only for `custom_webhook` tools whose `parameters` are a raw JSON Schema object. Can be sent on its own to move existing parameters without resending `parameters`; entries are merged over the tool's current placement, so parameters left out keep where they were. Every key must name a top-level parameter. For POST webhooks, every parameter needs a placement. For GET webhooks, unplaced parameters default to `"query_string"` and `"request_body"` is not allowed.
  - Allowed values: `request_body`, `query_string`, `url_path`
- `endpoint_method` (enum, optional) — HTTP method for webhook tools. When switching from POST to GET, a tool with request body parameters must also send new `parameters` (or `parameter_locations`) placing them in the query string.
  - Allowed values: `GET`, `POST`
- `endpoint_url` (string, optional) — URL for webhook tools. Must be a publicly routable HTTPS URL without embedded credentials. May contain `{name}` placeholders in the path or query (not the scheme, host, port, or credentials), each filled by a required parameter with location `"url_path"`.
- `endpoint_headers` (map from string to string, optional, nullable) — Headers for webhook tools. Set to null to clear existing headers.
- `endpoint_timeout_ms` (integer, optional)
- `tool_call_output_timeout_ms` (integer, optional)
- `phone_number` (string, optional, nullable) — The E.164 formatted phone number to transfer calls to. Set to null if the agent should determine the phone number.
- `sip` (TransferSip, optional, nullable) — A SIP destination to transfer calls to instead of a phone number. Setting sip clears phone_number, and setting phone_number clears sip; they cannot both be set in one update. Can be set to null to remove the SIP destination. Only applicable to built_in_transfer_to_phone_number tools.
- `dtmf` (string, optional, nullable) — DTMF digits to send after the transfer connects (e.g., "1234"). Can be set to null to remove DTMF. Ignored when dynamic_dtmf is true.
- `post_transfer_message` (string, optional, nullable) — Fixed line the agent speaks into the bridged call once the transfer connects. Can be set to null to remove the announcement. Must be null when the resulting keep_listening is false. Only applicable to built_in_transfer_to_phone_number tools.
- `dynamic_dtmf` (boolean, optional) — When true, the agent determines the DTMF digits at call time (and may choose to send none); the static dtmf is ignored.
- `use_agent_phone_number` (boolean, optional) — When true, Phonic will transfer the call using the agent's phone number. When false, Phonic will transfer the call using the phone number of the party to whom the agent is connected. This is only available for built_in_transfer_to_phone_number tools.
- `detect_voicemail` (boolean, optional) — When true, Phonic will listen in and tell the user if the transfer hits voicemail. This is only available for built_in_transfer_to_phone_number tools when use_agent_phone_number is true.
- `keep_listening` (boolean, optional) — When true, Phonic bridges the transfer and stays on the call. When false, Phonic drops out once the transfer connects, which requires the resulting use_agent_phone_number and detect_voicemail to be false and post_transfer_message to be null. Without DTMF the call is handed off with a SIP REFER; with DTMF (static or dynamic) Phonic bridges the call to send the digits and then detaches, leaving the two parties connected. Only applicable to built_in_transfer_to_phone_number tools.
- `on_transfer_no_answer` (enum, optional) — What happens when the transfer target does not answer before the ring timeout. `return_to_assistant` hands control back to the agent. `keep_retrying` keeps the caller on the line and re-dials the target until it answers, the caller hangs up, or a retry cap is reached, then returns to the assistant. `keep_retrying` only applies to bridged transfers, so it cannot be used when the resulting keep_listening is false. Only applicable to built_in_transfer_to_phone_number tools.
  - Allowed values: `return_to_assistant`, `keep_retrying`
- `agents_to_transfer_to` (list of string, optional) — Array of agent names that the LLM can choose from when transferring. All agents must exist in the same project as the tool.
- `require_speech_before_tool_call` (boolean, optional) — When true, forces the agent to speak before executing the tool.
- `speech_before_tool_call` (enum, optional) — For built_in_natural_conversation_ending and built_in_keypad_input tools. Whether the agent must speak before calling the tool ("required"), the model decides ("optional"), or the agent must stay silent ("suppressed"). Not used by other tool types.
  - Allowed values: `required`, `optional`, `suppressed`
- `respond_after_sec` (double, optional, nullable) — For built_in_choose_not_to_respond tools. Number of seconds to wait after the tool fires before the agent speaks a follow-up if the user stays silent. When null, the agent stays silent (default). Not used by other tool types.
- `wait_for_speech_before_tool_call` (boolean, optional) — If true, the agent will wait to finish speaking before executing the tool. This is only available for custom_webhook and custom_websocket tools.
- `forbid_speech_after_tool_call` (boolean, optional) — When true, forbids the agent from speaking after executing the tool. Available for custom_context, custom_webhook and custom_websocket tools.
- `forbid_tool_call_after_speech` (boolean, optional) — When true, forbids the agent from calling the tool right after it has spoken. Available for custom_webhook and custom_websocket tools.
- `allow_tool_chaining` (boolean, optional) — When true, allows the agent to chain and execute other tools after executing the tool. Available for custom_context, custom_webhook and custom_websocket tools.
- `wait_for_response` (boolean, optional) — The agent doesn't typically wait for the response of async tools. When true, makes the agent wait for a response, not call other tools and inform the user of the result. Only available for async custom_webhook and custom_websocket tools, and cannot be combined with allow_tool_chaining set to true.
- `uninterruptible` (boolean, optional) — When true, caller speech cannot interrupt the assistant while the tool call is running. Available for sync custom_webhook, sync custom_websocket, and built_in_transfer_to_phone_number tools. Omitted updates preserve the current setting. Prevents caller interruptions during the transfer, including the preceding announcement once protection is active.
- `can_run_during_user_speech` (boolean, optional) — When true, the agent can call the tool while the user is still speaking. Only available for custom_webhook, custom_websocket, and custom_context tools. Setting it to true requires the feature to be enabled for your organization; contact Phonic to get access.

## Response

### 200

Success response

- `success` (boolean, required) — Whether the tool was updated successfully.

## Errors

### 400 Bad Request Error

Invalid parameters

- `Error`
  - BasicError: BasicError
  - ValidationError: ValidationError

### 404 Not Found Error

Tool not found

- `error` (BasicErrorError, optional)

### 409 Conflict Error

Tool name already exists

- `error` (ValidationErrorError, required)
- `param_errors` (map from string to string, required) — Parameter-specific validation errors

## Types

### UpdateToolRequestParameters

The tool's parameters, either as a flat array of parameter definitions or as a raw JSON Schema object (use the object form for nested parameters). Replaces the tool's existing parameters, including the form they are stored in. For `custom_webhook` tools: when sending an array, `location` is required for POST and defaults to `"query_string"` for GET, and `parameter_locations` must not be sent; when sending a JSON Schema object, placement is supplied in `parameter_locations`. For `custom_websocket`, `built_in_transfer_to_phone_number`, and `built_in_transfer_to_agent` tools: `location` must not be specified.

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

### Update tool response

**Response**

```json
{
  "success": true
}
```

**SDK Code**

```python Update tool response
import requests

url = "https://api.phonic.ai/v1/tools/nameOrId"

querystring = {"project":"main"}

headers = {"Authorization": "Bearer <apiKey>"}

response = requests.patch(url, headers=headers, params=querystring)

print(response.json())
```

```javascript Update tool response
const url = 'https://api.phonic.ai/v1/tools/nameOrId?project=main';
const options = {method: 'PATCH', headers: {Authorization: 'Bearer <apiKey>'}};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go Update tool response
package main

import (
	"fmt"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/tools/nameOrId?project=main"

	req, _ := http.NewRequest("PATCH", url, nil)

	req.Header.Add("Authorization", "Bearer <apiKey>")

	res, _ := http.DefaultClient.Do(req)

	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)

	fmt.Println(res)
	fmt.Println(string(body))

}
```

```ruby Update tool response
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/tools/nameOrId?project=main")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Patch.new(url)
request["Authorization"] = 'Bearer <apiKey>'

response = http.request(request)
puts response.read_body
```

```java Update tool response
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.patch("https://api.phonic.ai/v1/tools/nameOrId?project=main")
  .header("Authorization", "Bearer <apiKey>")
  .asString();
```

```php Update tool response
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('PATCH', 'https://api.phonic.ai/v1/tools/nameOrId?project=main', [
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
  ],
]);

echo $response->getBody();
```

```csharp Update tool response
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/tools/nameOrId?project=main");
var request = new RestRequest(Method.PATCH);
request.AddHeader("Authorization", "Bearer <apiKey>");
IRestResponse response = client.Execute(request);
```

```swift Update tool response
import Foundation

let headers = ["Authorization": "Bearer <apiKey>"]

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/tools/nameOrId?project=main")! as URL,
                                        cachePolicy: .useProtocolCachePolicy,
                                    timeoutInterval: 10.0)
request.httpMethod = "PATCH"
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

### tools_update_example

**Request**

```json
{
  "description": "Updated description for booking appointments with enhanced features",
  "endpoint_headers": {
    "Authorization": "Bearer updated_token456"
  },
  "endpoint_timeout_ms": 7000
}
```

**Response**

```json
{
  "success": true
}
```

**SDK Code**

```python tools_update_example
import requests

url = "https://api.phonic.ai/v1/tools/nameOrId"

querystring = {"project":"main"}

payload = {
    "description": "Updated description for booking appointments with enhanced features",
    "endpoint_headers": { "Authorization": "Bearer updated_token456" },
    "endpoint_timeout_ms": 7000
}
headers = {
    "Authorization": "Bearer <apiKey>",
    "Content-Type": "application/json"
}

response = requests.patch(url, json=payload, headers=headers, params=querystring)

print(response.json())
```

```javascript tools_update_example
const url = 'https://api.phonic.ai/v1/tools/nameOrId?project=main';
const options = {
  method: 'PATCH',
  headers: {Authorization: 'Bearer <apiKey>', 'Content-Type': 'application/json'},
  body: '{"description":"Updated description for booking appointments with enhanced features","endpoint_headers":{"Authorization":"Bearer updated_token456"},"endpoint_timeout_ms":7000}'
};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go tools_update_example
package main

import (
	"fmt"
	"strings"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/tools/nameOrId?project=main"

	payload := strings.NewReader("{\n  \"description\": \"Updated description for booking appointments with enhanced features\",\n  \"endpoint_headers\": {\n    \"Authorization\": \"Bearer updated_token456\"\n  },\n  \"endpoint_timeout_ms\": 7000\n}")

	req, _ := http.NewRequest("PATCH", url, payload)

	req.Header.Add("Authorization", "Bearer <apiKey>")
	req.Header.Add("Content-Type", "application/json")

	res, _ := http.DefaultClient.Do(req)

	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)

	fmt.Println(res)
	fmt.Println(string(body))

}
```

```ruby tools_update_example
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/tools/nameOrId?project=main")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Patch.new(url)
request["Authorization"] = 'Bearer <apiKey>'
request["Content-Type"] = 'application/json'
request.body = "{\n  \"description\": \"Updated description for booking appointments with enhanced features\",\n  \"endpoint_headers\": {\n    \"Authorization\": \"Bearer updated_token456\"\n  },\n  \"endpoint_timeout_ms\": 7000\n}"

response = http.request(request)
puts response.read_body
```

```java tools_update_example
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.patch("https://api.phonic.ai/v1/tools/nameOrId?project=main")
  .header("Authorization", "Bearer <apiKey>")
  .header("Content-Type", "application/json")
  .body("{\n  \"description\": \"Updated description for booking appointments with enhanced features\",\n  \"endpoint_headers\": {\n    \"Authorization\": \"Bearer updated_token456\"\n  },\n  \"endpoint_timeout_ms\": 7000\n}")
  .asString();
```

```php tools_update_example
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('PATCH', 'https://api.phonic.ai/v1/tools/nameOrId?project=main', [
  'body' => '{
  "description": "Updated description for booking appointments with enhanced features",
  "endpoint_headers": {
    "Authorization": "Bearer updated_token456"
  },
  "endpoint_timeout_ms": 7000
}',
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
    'Content-Type' => 'application/json',
  ],
]);

echo $response->getBody();
```

```csharp tools_update_example
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/tools/nameOrId?project=main");
var request = new RestRequest(Method.PATCH);
request.AddHeader("Authorization", "Bearer <apiKey>");
request.AddHeader("Content-Type", "application/json");
request.AddParameter("application/json", "{\n  \"description\": \"Updated description for booking appointments with enhanced features\",\n  \"endpoint_headers\": {\n    \"Authorization\": \"Bearer updated_token456\"\n  },\n  \"endpoint_timeout_ms\": 7000\n}", ParameterType.RequestBody);
IRestResponse response = client.Execute(request);
```

```swift tools_update_example
import Foundation

let headers = [
  "Authorization": "Bearer <apiKey>",
  "Content-Type": "application/json"
]
let parameters = [
  "description": "Updated description for booking appointments with enhanced features",
  "endpoint_headers": ["Authorization": "Bearer updated_token456"],
  "endpoint_timeout_ms": 7000
] as [String : Any]

let postData = JSONSerialization.data(withJSONObject: parameters, options: [])

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/tools/nameOrId?project=main")! as URL,
                                        cachePolicy: .useProtocolCachePolicy,
                                    timeoutInterval: 10.0)
request.httpMethod = "PATCH"
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