> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Replay

POST https://api.phonic.ai/v1/conversation_items/{id}/replay
Content-Type: application/json

Returns the alternative response(s) the assistant would have
produced for this conversation turn given changes to the agent system prompt.

Only assistant items from ended conversations can be replayed. Omit the
request body (or omit `system_prompt`) to replay the turn exactly as it
originally ran.


Reference: https://docs.phonic.ai/api-reference/conversation-items/replay

## Authentication

- `Authorization` header (bearer token, required) — Bearer authentication header of the form `Bearer <PHONIC_API_KEY>`. Manage your API keys [here](https://phonic.co/api-keys).

## Request

### Path parameters

- `id` (string, required) — The ID of the conversation item to replay.

### Body (application/json)

This endpoint expects a ReplayConversationItemRequest.

- `system_prompt` (string, optional) — The system prompt to use when generating replay responses. Use this to test prompt changes against this conversation turn. Omit it to replay the turn with the system prompt it originally ran with.
- `num_responses` (integer, optional, default: 1) — Number of alternative responses to generate.

## Response

### 200

Success response

- `responses` (list of ReplayConversationItemResponseResponsesItems, required) — Alternative responses generated for the conversation item.

## Errors

### 400 Bad Request Error

Malformed JSON or invalid request body

- `Error`
  - BasicError: BasicError
  - ValidationError: ValidationError

### 401 Unauthorized Error

Unauthorized (authentication missing or invalid)

- `error` (BasicErrorError, optional)

### 403 Forbidden Error

Forbidden

- `error` (BasicErrorError, optional)

### 404 Not Found Error

Conversation item not found

- `error` (BasicErrorError, optional)

### 409 Conflict Error

Conversation is still live, or the agent is disabled

- `error` (BasicErrorError, optional)

### 422 Unprocessable Entity Error

Conversation item cannot be replayed (not an assistant item, or the conversation's transcripts were deleted)

- `error` (BasicErrorError, optional)

### 500 Internal Server Error

Internal server error

- `error` (BasicErrorError, optional)

## Types

### ReplayConversationItemResponseResponsesItems

- `text` (string, required) — The text the LLM produced for this replay response.
- `tool_calls` (list of ReplayToolCall, required) — Tool calls the LLM would invoke for this replay response - note that the tools will not actually be called during replay.

### BasicError

- `error` (BasicErrorError, optional)

### ValidationError

- `error` (ValidationErrorError, required)
- `param_errors` (map from string to string, required) — Parameter-specific validation errors

### BasicErrorError

- `message` (string, required) — Error message
- `code` (string, optional) — Error code

### ReplayToolCall

- `tool` (ReplayToolCallTool, required)
- `request_body` (map from string to any, required, nullable) — Request body the LLM produced for the tool call.
- `endpoint_method` (enum, optional) — HTTP method for webhook tool calls.
  - Allowed values: `GET`, `POST`
- `endpoint_url` (string, optional) — URL for webhook tool calls.
- `endpoint_headers` (map from string to string, optional, nullable) — Headers for webhook tool calls.
- `query_params` (map from string to string, optional, nullable) — Query parameters the LLM produced for webhook tool calls.
- `context` (string, optional) — Context returned from custom-context tool calls.

### ValidationErrorError

- `message` (string, required) — Error message

### ReplayToolCallTool

- `id` (string, required) — The tool ID.
- `name` (string, required) — The tool name.

## Examples

**Request**

```json
{}
```

**Response**

```json
{
  "responses": [
    {
      "text": "Sure — I can help with that. What time works best?",
      "tool_calls": []
    }
  ]
}
```

**SDK Code**

```python Replay conversation item response
import requests

url = "https://api.phonic.ai/v1/conversation_items/id/replay"

payload = {}
headers = {
    "Authorization": "Bearer <apiKey>",
    "Content-Type": "application/json"
}

response = requests.post(url, json=payload, headers=headers)

print(response.json())
```

```javascript Replay conversation item response
const url = 'https://api.phonic.ai/v1/conversation_items/id/replay';
const options = {
  method: 'POST',
  headers: {Authorization: 'Bearer <apiKey>', 'Content-Type': 'application/json'},
  body: '{}'
};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go Replay conversation item response
package main

import (
	"fmt"
	"strings"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/conversation_items/id/replay"

	payload := strings.NewReader("{}")

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

```ruby Replay conversation item response
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/conversation_items/id/replay")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Post.new(url)
request["Authorization"] = 'Bearer <apiKey>'
request["Content-Type"] = 'application/json'
request.body = "{}"

response = http.request(request)
puts response.read_body
```

```java Replay conversation item response
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.post("https://api.phonic.ai/v1/conversation_items/id/replay")
  .header("Authorization", "Bearer <apiKey>")
  .header("Content-Type", "application/json")
  .body("{}")
  .asString();
```

```php Replay conversation item response
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('POST', 'https://api.phonic.ai/v1/conversation_items/id/replay', [
  'body' => '{}',
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
    'Content-Type' => 'application/json',
  ],
]);

echo $response->getBody();
```

```csharp Replay conversation item response
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/conversation_items/id/replay");
var request = new RestRequest(Method.POST);
request.AddHeader("Authorization", "Bearer <apiKey>");
request.AddHeader("Content-Type", "application/json");
request.AddParameter("application/json", "{}", ParameterType.RequestBody);
IRestResponse response = client.Execute(request);
```

```swift Replay conversation item response
import Foundation

let headers = [
  "Authorization": "Bearer <apiKey>",
  "Content-Type": "application/json"
]
let parameters = [] as [String : Any]

let postData = JSONSerialization.data(withJSONObject: parameters, options: [])

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/conversation_items/id/replay")! as URL,
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