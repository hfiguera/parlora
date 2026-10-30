> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Get

GET https://api.phonic.ai/v1/workspace

Returns information about the workspace.

Reference: https://docs.phonic.ai/api-reference/workspace/get

## Authentication

- `Authorization` header (bearer token, required) — Bearer authentication header of the form `Bearer <PHONIC_API_KEY>`. Manage your API keys [here](https://phonic.co/api-keys).

## Response

### 200

Success response

- `active_conversations` (integer, required) — Number of conversations currently in progress for this workspace.
- `max_active_conversations` (integer, required) — Maximum number of concurrent conversations allowed for this workspace.
- `logo_url` (string, required, nullable) — URL of the workspace logo (PNG or SVG), or null if not set.
- `invite_link_allowed_domains` (list of string, required) — Email domains allowed to join the workspace via invite link.
- `ip_allowlist` (list of string, required) — IP addresses or CIDR ranges allowed to access the workspace.

## Errors

### 401 Unauthorized Error

Unauthorized

- `error` (BasicErrorError, optional)

### 500 Internal Server Error

Internal server error

- `error` (BasicErrorError, optional)

## Types

### BasicErrorError

- `message` (string, required) — Error message
- `code` (string, optional) — Error code

## Examples

**Response**

```json
{
  "active_conversations": 3,
  "max_active_conversations": 10,
  "logo_url": "https://example.com/logo.png",
  "invite_link_allowed_domains": [
    "example.com"
  ],
  "ip_allowlist": [
    "203.0.113.0/24"
  ]
}
```

**SDK Code**

```python Workspace usage
import requests

url = "https://api.phonic.ai/v1/workspace"

headers = {"Authorization": "Bearer <apiKey>"}

response = requests.get(url, headers=headers)

print(response.json())
```

```javascript Workspace usage
const url = 'https://api.phonic.ai/v1/workspace';
const options = {method: 'GET', headers: {Authorization: 'Bearer <apiKey>'}};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go Workspace usage
package main

import (
	"fmt"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/workspace"

	req, _ := http.NewRequest("GET", url, nil)

	req.Header.Add("Authorization", "Bearer <apiKey>")

	res, _ := http.DefaultClient.Do(req)

	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)

	fmt.Println(res)
	fmt.Println(string(body))

}
```

```ruby Workspace usage
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/workspace")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Get.new(url)
request["Authorization"] = 'Bearer <apiKey>'

response = http.request(request)
puts response.read_body
```

```java Workspace usage
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.get("https://api.phonic.ai/v1/workspace")
  .header("Authorization", "Bearer <apiKey>")
  .asString();
```

```php Workspace usage
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('GET', 'https://api.phonic.ai/v1/workspace', [
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
  ],
]);

echo $response->getBody();
```

```csharp Workspace usage
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/workspace");
var request = new RestRequest(Method.GET);
request.AddHeader("Authorization", "Bearer <apiKey>");
IRestResponse response = client.Execute(request);
```

```swift Workspace usage
import Foundation

let headers = ["Authorization": "Bearer <apiKey>"]

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/workspace")! as URL,
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