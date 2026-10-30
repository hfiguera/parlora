> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Replay

POST https://api.phonic.ai/v1/conversations/{id}/replay
Content-Type: application/json

Replays an ended conversation by re-running its recorded audio through an
agent. Requires API key or access token authentication. The conversation must
have audio recordings available and an associated agent (or one specified in
the request body).


Reference: https://docs.phonic.ai/api-reference/conversations/replay

## Authentication

- `Authorization` header (bearer token, required) — Bearer authentication header of the form `Bearer <PHONIC_API_KEY>`. Manage your API keys [here](https://phonic.co/api-keys).

## Request

### Path parameters

- `id` (string, required) — The ID of the conversation to replay.

### Body (application/json)

This endpoint expects a ReplayConversationRequest.

- `agent` (string, optional) — Name of the agent to replay the conversation with. Defaults to the agent originally associated with the conversation.

## Response

### 200

Replay started

- `message` (string, required) — Confirmation that the replay has started.

## Errors

### 400 Bad Request Error

Invalid parameters

- `error` (ValidationErrorError, required)
- `param_errors` (map from string to string, required) — Parameter-specific validation errors

### 401 Unauthorized Error

Unauthorized (authentication missing or invalid)

- `error` (BasicErrorError, optional)

### 403 Forbidden Error

Forbidden

- `error` (BasicErrorError, optional)

### 404 Not Found Error

Conversation not found

- `error` (BasicErrorError, optional)

### 409 Conflict Error

Cannot replay an active conversation, or the agent is disabled

- `error` (BasicErrorError, optional)

### 422 Unprocessable Entity Error

Conversation cannot be replayed (no audio, deleted recordings, or no agent)

- `error` (BasicErrorError, optional)

### 429 Too Many Requests Error

Concurrency limit reached

- `error` (BasicErrorError, optional)

### 500 Internal Server Error

Internal server error

- `error` (BasicErrorError, optional)

### 503 Service Unavailable Error

Insufficient capacity available to start the replay.

- `error` (BasicErrorError, optional)

## Types

### ValidationErrorError

- `message` (string, required) — Error message

### BasicErrorError

- `message` (string, required) — Error message
- `code` (string, optional) — Error code

## Examples

**Request**

```json
{
  "agent": "support-agent"
}
```

**Response**

```json
{
  "message": "Replay started"
}
```

**SDK Code**

```python conversations_replay_example
import requests

url = "https://api.phonic.ai/v1/conversations/id/replay"

payload = { "agent": "support-agent" }
headers = {
    "Authorization": "Bearer <apiKey>",
    "Content-Type": "application/json"
}

response = requests.post(url, json=payload, headers=headers)

print(response.json())
```

```javascript conversations_replay_example
const url = 'https://api.phonic.ai/v1/conversations/id/replay';
const options = {
  method: 'POST',
  headers: {Authorization: 'Bearer <apiKey>', 'Content-Type': 'application/json'},
  body: '{"agent":"support-agent"}'
};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go conversations_replay_example
package main

import (
	"fmt"
	"strings"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/conversations/id/replay"

	payload := strings.NewReader("{\n  \"agent\": \"support-agent\"\n}")

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

```ruby conversations_replay_example
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/conversations/id/replay")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Post.new(url)
request["Authorization"] = 'Bearer <apiKey>'
request["Content-Type"] = 'application/json'
request.body = "{\n  \"agent\": \"support-agent\"\n}"

response = http.request(request)
puts response.read_body
```

```java conversations_replay_example
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.post("https://api.phonic.ai/v1/conversations/id/replay")
  .header("Authorization", "Bearer <apiKey>")
  .header("Content-Type", "application/json")
  .body("{\n  \"agent\": \"support-agent\"\n}")
  .asString();
```

```php conversations_replay_example
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('POST', 'https://api.phonic.ai/v1/conversations/id/replay', [
  'body' => '{
  "agent": "support-agent"
}',
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
    'Content-Type' => 'application/json',
  ],
]);

echo $response->getBody();
```

```csharp conversations_replay_example
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/conversations/id/replay");
var request = new RestRequest(Method.POST);
request.AddHeader("Authorization", "Bearer <apiKey>");
request.AddHeader("Content-Type", "application/json");
request.AddParameter("application/json", "{\n  \"agent\": \"support-agent\"\n}", ParameterType.RequestBody);
IRestResponse response = client.Execute(request);
```

```swift conversations_replay_example
import Foundation

let headers = [
  "Authorization": "Bearer <apiKey>",
  "Content-Type": "application/json"
]
let parameters = ["agent": "support-agent"] as [String : Any]

let postData = JSONSerialization.data(withJSONObject: parameters, options: [])

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/conversations/id/replay")! as URL,
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