> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Create Conversation Token

POST https://api.phonic.ai/v1/auth/conversation_token
Content-Type: application/json

Creates a short-lived conversation token scoped to a specific agent. Conversation tokens are useful for client-side applications that start a conversation with a single agent without exposing your API key.

Reference: https://docs.phonic.ai/api-reference/auth/create-conversation-token

## Authentication

- `Authorization` header (bearer token, required) — Bearer authentication header of the form `Bearer <PHONIC_API_KEY>`. Manage your API keys [here](https://phonic.co/api-keys).

## Request

### Body (application/json)

This endpoint expects a CreateConversationTokenRequest.

- `agent_id` (string, required) — ID of the agent the conversation token is scoped to.
- `ttl_seconds` (integer, optional, default: 30) — Time-to-live for the conversation token in seconds.

## Response

### 200

Success response

- `conversation_token` (string, required) — The conversation token to use for authentication.
- `expires_at` (string, required) — When the conversation token expires.

## Errors

### 400 Bad Request Error

Invalid parameters

- `error` (ValidationErrorError, required)
- `param_errors` (map from string to string, required) — Parameter-specific validation errors

### 401 Unauthorized Error

Unauthorized (authentication missing or invalid)

- `error` (BasicErrorError, optional)

### 403 Forbidden Error

Forbidden (only API keys can create conversation tokens)

- `error` (BasicErrorError, optional)

### 404 Not Found Error

Agent not found

- `error` (BasicErrorError, optional)

### 409 Conflict Error

Agent is disabled

- `error` (BasicErrorError, optional)

### 500 Internal Server Error

Internal server error

- `error` (BasicErrorError, optional)

## Types

### ValidationErrorError

- `message` (string, required) — Error message

### BasicErrorError

- `message` (string, required) — Error message
- `code` (string, optional) — Error code

## Examples

### Created conversation token response

**Response**

```json
{
  "conversation_token": "ph_conversation_abc123def456...",
  "expires_at": "2025-07-30T23:50:00.000Z"
}
```

**SDK Code**

```python Created conversation token response
import requests

url = "https://api.phonic.ai/v1/auth/conversation_token"

headers = {"Authorization": "Bearer <apiKey>"}

response = requests.post(url, headers=headers)

print(response.json())
```

```javascript Created conversation token response
const url = 'https://api.phonic.ai/v1/auth/conversation_token';
const options = {method: 'POST', headers: {Authorization: 'Bearer <apiKey>'}};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go Created conversation token response
package main

import (
	"fmt"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/auth/conversation_token"

	req, _ := http.NewRequest("POST", url, nil)

	req.Header.Add("Authorization", "Bearer <apiKey>")

	res, _ := http.DefaultClient.Do(req)

	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)

	fmt.Println(res)
	fmt.Println(string(body))

}
```

```ruby Created conversation token response
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/auth/conversation_token")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Post.new(url)
request["Authorization"] = 'Bearer <apiKey>'

response = http.request(request)
puts response.read_body
```

```java Created conversation token response
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.post("https://api.phonic.ai/v1/auth/conversation_token")
  .header("Authorization", "Bearer <apiKey>")
  .asString();
```

```php Created conversation token response
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('POST', 'https://api.phonic.ai/v1/auth/conversation_token', [
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
  ],
]);

echo $response->getBody();
```

```csharp Created conversation token response
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/auth/conversation_token");
var request = new RestRequest(Method.POST);
request.AddHeader("Authorization", "Bearer <apiKey>");
IRestResponse response = client.Execute(request);
```

```swift Created conversation token response
import Foundation

let headers = ["Authorization": "Bearer <apiKey>"]

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/auth/conversation_token")! as URL,
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

### auth_create_conversation_token_example

**Request**

```json
{
  "agent_id": "agent_12cf6e88-c254-4d3e-a149-a7f1bdd22783",
  "ttl_seconds": 30
}
```

**Response**

```json
{
  "conversation_token": "ph_conversation_abc123def456...",
  "expires_at": "2025-07-30T23:50:00.000Z"
}
```

**SDK Code**

```python auth_create_conversation_token_example
import requests

url = "https://api.phonic.ai/v1/auth/conversation_token"

payload = {
    "agent_id": "agent_12cf6e88-c254-4d3e-a149-a7f1bdd22783",
    "ttl_seconds": 30
}
headers = {
    "Authorization": "Bearer <apiKey>",
    "Content-Type": "application/json"
}

response = requests.post(url, json=payload, headers=headers)

print(response.json())
```

```javascript auth_create_conversation_token_example
const url = 'https://api.phonic.ai/v1/auth/conversation_token';
const options = {
  method: 'POST',
  headers: {Authorization: 'Bearer <apiKey>', 'Content-Type': 'application/json'},
  body: '{"agent_id":"agent_12cf6e88-c254-4d3e-a149-a7f1bdd22783","ttl_seconds":30}'
};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go auth_create_conversation_token_example
package main

import (
	"fmt"
	"strings"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/auth/conversation_token"

	payload := strings.NewReader("{\n  \"agent_id\": \"agent_12cf6e88-c254-4d3e-a149-a7f1bdd22783\",\n  \"ttl_seconds\": 30\n}")

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

```ruby auth_create_conversation_token_example
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/auth/conversation_token")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Post.new(url)
request["Authorization"] = 'Bearer <apiKey>'
request["Content-Type"] = 'application/json'
request.body = "{\n  \"agent_id\": \"agent_12cf6e88-c254-4d3e-a149-a7f1bdd22783\",\n  \"ttl_seconds\": 30\n}"

response = http.request(request)
puts response.read_body
```

```java auth_create_conversation_token_example
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.post("https://api.phonic.ai/v1/auth/conversation_token")
  .header("Authorization", "Bearer <apiKey>")
  .header("Content-Type", "application/json")
  .body("{\n  \"agent_id\": \"agent_12cf6e88-c254-4d3e-a149-a7f1bdd22783\",\n  \"ttl_seconds\": 30\n}")
  .asString();
```

```php auth_create_conversation_token_example
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('POST', 'https://api.phonic.ai/v1/auth/conversation_token', [
  'body' => '{
  "agent_id": "agent_12cf6e88-c254-4d3e-a149-a7f1bdd22783",
  "ttl_seconds": 30
}',
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
    'Content-Type' => 'application/json',
  ],
]);

echo $response->getBody();
```

```csharp auth_create_conversation_token_example
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/auth/conversation_token");
var request = new RestRequest(Method.POST);
request.AddHeader("Authorization", "Bearer <apiKey>");
request.AddHeader("Content-Type", "application/json");
request.AddParameter("application/json", "{\n  \"agent_id\": \"agent_12cf6e88-c254-4d3e-a149-a7f1bdd22783\",\n  \"ttl_seconds\": 30\n}", ParameterType.RequestBody);
IRestResponse response = client.Execute(request);
```

```swift auth_create_conversation_token_example
import Foundation

let headers = [
  "Authorization": "Bearer <apiKey>",
  "Content-Type": "application/json"
]
let parameters = [
  "agent_id": "agent_12cf6e88-c254-4d3e-a149-a7f1bdd22783",
  "ttl_seconds": 30
] as [String : Any]

let postData = JSONSerialization.data(withJSONObject: parameters, options: [])

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/auth/conversation_token")! as URL,
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