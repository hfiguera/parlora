> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Create Session Token

POST https://api.phonic.ai/v1/auth/session_token
Content-Type: application/json

Creates a short-lived session token that can be used to authenticate WebSocket connections. Session tokens are useful for client-side applications where you don't want to expose your API key.

Reference: https://docs.phonic.ai/api-reference/auth/create-session-token

## Authentication

- `Authorization` header (bearer token, required) — Bearer authentication header of the form `Bearer <PHONIC_API_KEY>`. Manage your API keys [here](https://phonic.co/api-keys).

## Request

### Body (application/json)

This endpoint expects a CreateSessionTokenRequest.

- `ttl_seconds` (integer, optional, default: 300) — Time-to-live for the session token in seconds.
- `conversation_ids` (list of string, optional) — Restricts the token to these conversations. A restricted token can read only their live audio and transcript, and cannot open the STS WebSocket or create an STS session. Omit it and the token can read any live conversation in the org. Pass it whenever the token will reach an end user's browser.

## Response

### 200

Success response

- `session_token` (string, required) — The session token to use for authentication.
- `expires_at` (string, required) — When the session token expires.

## Errors

### 400 Bad Request Error

Invalid parameters

- `error` (ValidationErrorError, required)
- `param_errors` (map from string to string, required) — Parameter-specific validation errors

### 401 Unauthorized Error

Unauthorized (authentication missing or invalid)

- `error` (BasicErrorError, optional)

### 403 Forbidden Error

Forbidden (only API keys can create session tokens)

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

### Created session token response

**Response**

```json
{
  "session_token": "ph_session_abc123def456...",
  "expires_at": "2025-07-30T23:50:00.000Z"
}
```

**SDK Code**

```python Created session token response
import requests

url = "https://api.phonic.ai/v1/auth/session_token"

headers = {"Authorization": "Bearer <apiKey>"}

response = requests.post(url, headers=headers)

print(response.json())
```

```javascript Created session token response
const url = 'https://api.phonic.ai/v1/auth/session_token';
const options = {method: 'POST', headers: {Authorization: 'Bearer <apiKey>'}};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go Created session token response
package main

import (
	"fmt"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/auth/session_token"

	req, _ := http.NewRequest("POST", url, nil)

	req.Header.Add("Authorization", "Bearer <apiKey>")

	res, _ := http.DefaultClient.Do(req)

	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)

	fmt.Println(res)
	fmt.Println(string(body))

}
```

```ruby Created session token response
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/auth/session_token")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Post.new(url)
request["Authorization"] = 'Bearer <apiKey>'

response = http.request(request)
puts response.read_body
```

```java Created session token response
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.post("https://api.phonic.ai/v1/auth/session_token")
  .header("Authorization", "Bearer <apiKey>")
  .asString();
```

```php Created session token response
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('POST', 'https://api.phonic.ai/v1/auth/session_token', [
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
  ],
]);

echo $response->getBody();
```

```csharp Created session token response
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/auth/session_token");
var request = new RestRequest(Method.POST);
request.AddHeader("Authorization", "Bearer <apiKey>");
IRestResponse response = client.Execute(request);
```

```swift Created session token response
import Foundation

let headers = ["Authorization": "Bearer <apiKey>"]

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/auth/session_token")! as URL,
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

### auth_create_session_token_example

**Request**

```json
{
  "ttl_seconds": 300
}
```

**Response**

```json
{
  "session_token": "ph_session_abc123def456...",
  "expires_at": "2025-07-30T23:50:00.000Z"
}
```

**SDK Code**

```python auth_create_session_token_example
import requests

url = "https://api.phonic.ai/v1/auth/session_token"

payload = { "ttl_seconds": 300 }
headers = {
    "Authorization": "Bearer <apiKey>",
    "Content-Type": "application/json"
}

response = requests.post(url, json=payload, headers=headers)

print(response.json())
```

```javascript auth_create_session_token_example
const url = 'https://api.phonic.ai/v1/auth/session_token';
const options = {
  method: 'POST',
  headers: {Authorization: 'Bearer <apiKey>', 'Content-Type': 'application/json'},
  body: '{"ttl_seconds":300}'
};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go auth_create_session_token_example
package main

import (
	"fmt"
	"strings"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/auth/session_token"

	payload := strings.NewReader("{\n  \"ttl_seconds\": 300\n}")

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

```ruby auth_create_session_token_example
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/auth/session_token")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Post.new(url)
request["Authorization"] = 'Bearer <apiKey>'
request["Content-Type"] = 'application/json'
request.body = "{\n  \"ttl_seconds\": 300\n}"

response = http.request(request)
puts response.read_body
```

```java auth_create_session_token_example
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.post("https://api.phonic.ai/v1/auth/session_token")
  .header("Authorization", "Bearer <apiKey>")
  .header("Content-Type", "application/json")
  .body("{\n  \"ttl_seconds\": 300\n}")
  .asString();
```

```php auth_create_session_token_example
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('POST', 'https://api.phonic.ai/v1/auth/session_token', [
  'body' => '{
  "ttl_seconds": 300
}',
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
    'Content-Type' => 'application/json',
  ],
]);

echo $response->getBody();
```

```csharp auth_create_session_token_example
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/auth/session_token");
var request = new RestRequest(Method.POST);
request.AddHeader("Authorization", "Bearer <apiKey>");
request.AddHeader("Content-Type", "application/json");
request.AddParameter("application/json", "{\n  \"ttl_seconds\": 300\n}", ParameterType.RequestBody);
IRestResponse response = client.Execute(request);
```

```swift auth_create_session_token_example
import Foundation

let headers = [
  "Authorization": "Bearer <apiKey>",
  "Content-Type": "application/json"
]
let parameters = ["ttl_seconds": 300] as [String : Any]

let postData = JSONSerialization.data(withJSONObject: parameters, options: [])

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/auth/session_token")! as URL,
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