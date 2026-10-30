> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Disable

POST https://api.phonic.ai/v1/agents/{nameOrId}/disable

Disables an agent by name or ID. A disabled agent cannot start conversations or be updated, except to release its phone numbers.

Reference: https://docs.phonic.ai/api-reference/agents/disable

## Authentication

- `Authorization` header (bearer token, required) — Bearer authentication header of the form `Bearer <PHONIC_API_KEY>`. Manage your API keys [here](https://phonic.co/api-keys).

## Request

### Path parameters

- `nameOrId` (string, required) — The name or the ID of the agent.

### Query parameters

- `project` (string, optional, default: main) — The name of the project containing the agent. Only used when `nameOrId` is a name.

## Response

### 200

Success response

- `success` (boolean, required)

## Errors

### 403 Forbidden Error

Forbidden (resource belongs to a different organization)

- `error` (BasicErrorError, optional)

### 404 Not Found Error

Agent not found

- `error` (BasicErrorError, optional)

## Types

### BasicErrorError

- `message` (string, required) — Error message
- `code` (string, optional) — Error code

## Examples

**Response**

```json
{
  "success": true
}
```

**SDK Code**

```python Disable agent response
import requests

url = "https://api.phonic.ai/v1/agents/nameOrId/disable"

querystring = {"project":"main"}

headers = {"Authorization": "Bearer <apiKey>"}

response = requests.post(url, headers=headers, params=querystring)

print(response.json())
```

```javascript Disable agent response
const url = 'https://api.phonic.ai/v1/agents/nameOrId/disable?project=main';
const options = {method: 'POST', headers: {Authorization: 'Bearer <apiKey>'}};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go Disable agent response
package main

import (
	"fmt"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/agents/nameOrId/disable?project=main"

	req, _ := http.NewRequest("POST", url, nil)

	req.Header.Add("Authorization", "Bearer <apiKey>")

	res, _ := http.DefaultClient.Do(req)

	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)

	fmt.Println(res)
	fmt.Println(string(body))

}
```

```ruby Disable agent response
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/agents/nameOrId/disable?project=main")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Post.new(url)
request["Authorization"] = 'Bearer <apiKey>'

response = http.request(request)
puts response.read_body
```

```java Disable agent response
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.post("https://api.phonic.ai/v1/agents/nameOrId/disable?project=main")
  .header("Authorization", "Bearer <apiKey>")
  .asString();
```

```php Disable agent response
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('POST', 'https://api.phonic.ai/v1/agents/nameOrId/disable?project=main', [
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
  ],
]);

echo $response->getBody();
```

```csharp Disable agent response
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/agents/nameOrId/disable?project=main");
var request = new RestRequest(Method.POST);
request.AddHeader("Authorization", "Bearer <apiKey>");
IRestResponse response = client.Execute(request);
```

```swift Disable agent response
import Foundation

let headers = ["Authorization": "Bearer <apiKey>"]

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/agents/nameOrId/disable?project=main")! as URL,
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