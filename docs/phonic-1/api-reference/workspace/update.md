> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Update

PATCH https://api.phonic.ai/v1/workspace
Content-Type: application/json

Updates the workspace.

Reference: https://docs.phonic.ai/api-reference/workspace/update

## Authentication

- `Authorization` header (bearer token, required) — Bearer authentication header of the form `Bearer <PHONIC_API_KEY>`. Manage your API keys [here](https://phonic.co/api-keys).

## Request

### Body (application/json)

This endpoint expects an UpdateWorkspaceRequest.

- `logo_url` (string, optional, nullable) — URL of the workspace logo. Must be an https URL ending in .png or .svg, or null to clear it.
- `invite_link_allowed_domains` (list of string, optional) — Email domains allowed to join the workspace via invite link.
- `ip_allowlist` (list of string, optional) — IP addresses or CIDR ranges allowed to access the workspace.

## Response

### 200

Success response

- `success` (boolean, required)

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

**Request**

```json
{
  "logo_url": "https://example.com/logo.png",
  "invite_link_allowed_domains": [
    "example.com"
  ],
  "ip_allowlist": [
    "203.0.113.0/24"
  ]
}
```

**Response**

```json
{
  "success": true
}
```

**SDK Code**

```python workspace_update_example
import requests

url = "https://api.phonic.ai/v1/workspace"

payload = {
    "logo_url": "https://example.com/logo.png",
    "invite_link_allowed_domains": ["example.com"],
    "ip_allowlist": ["203.0.113.0/24"]
}
headers = {
    "Authorization": "Bearer <apiKey>",
    "Content-Type": "application/json"
}

response = requests.patch(url, json=payload, headers=headers)

print(response.json())
```

```javascript workspace_update_example
const url = 'https://api.phonic.ai/v1/workspace';
const options = {
  method: 'PATCH',
  headers: {Authorization: 'Bearer <apiKey>', 'Content-Type': 'application/json'},
  body: '{"logo_url":"https://example.com/logo.png","invite_link_allowed_domains":["example.com"],"ip_allowlist":["203.0.113.0/24"]}'
};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go workspace_update_example
package main

import (
	"fmt"
	"strings"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/workspace"

	payload := strings.NewReader("{\n  \"logo_url\": \"https://example.com/logo.png\",\n  \"invite_link_allowed_domains\": [\n    \"example.com\"\n  ],\n  \"ip_allowlist\": [\n    \"203.0.113.0/24\"\n  ]\n}")

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

```ruby workspace_update_example
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/workspace")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Patch.new(url)
request["Authorization"] = 'Bearer <apiKey>'
request["Content-Type"] = 'application/json'
request.body = "{\n  \"logo_url\": \"https://example.com/logo.png\",\n  \"invite_link_allowed_domains\": [\n    \"example.com\"\n  ],\n  \"ip_allowlist\": [\n    \"203.0.113.0/24\"\n  ]\n}"

response = http.request(request)
puts response.read_body
```

```java workspace_update_example
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.patch("https://api.phonic.ai/v1/workspace")
  .header("Authorization", "Bearer <apiKey>")
  .header("Content-Type", "application/json")
  .body("{\n  \"logo_url\": \"https://example.com/logo.png\",\n  \"invite_link_allowed_domains\": [\n    \"example.com\"\n  ],\n  \"ip_allowlist\": [\n    \"203.0.113.0/24\"\n  ]\n}")
  .asString();
```

```php workspace_update_example
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('PATCH', 'https://api.phonic.ai/v1/workspace', [
  'body' => '{
  "logo_url": "https://example.com/logo.png",
  "invite_link_allowed_domains": [
    "example.com"
  ],
  "ip_allowlist": [
    "203.0.113.0/24"
  ]
}',
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
    'Content-Type' => 'application/json',
  ],
]);

echo $response->getBody();
```

```csharp workspace_update_example
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/workspace");
var request = new RestRequest(Method.PATCH);
request.AddHeader("Authorization", "Bearer <apiKey>");
request.AddHeader("Content-Type", "application/json");
request.AddParameter("application/json", "{\n  \"logo_url\": \"https://example.com/logo.png\",\n  \"invite_link_allowed_domains\": [\n    \"example.com\"\n  ],\n  \"ip_allowlist\": [\n    \"203.0.113.0/24\"\n  ]\n}", ParameterType.RequestBody);
IRestResponse response = client.Execute(request);
```

```swift workspace_update_example
import Foundation

let headers = [
  "Authorization": "Bearer <apiKey>",
  "Content-Type": "application/json"
]
let parameters = [
  "logo_url": "https://example.com/logo.png",
  "invite_link_allowed_domains": ["example.com"],
  "ip_allowlist": ["203.0.113.0/24"]
] as [String : Any]

let postData = JSONSerialization.data(withJSONObject: parameters, options: [])

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/workspace")! as URL,
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