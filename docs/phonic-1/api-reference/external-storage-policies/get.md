> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Get

GET https://api.phonic.ai/v1/external_storage_policies/{nameOrId}

Returns an external storage policy by name or ID.

Reference: https://docs.phonic.ai/api-reference/external-storage-policies/get

## Authentication

- `Authorization` header (bearer token, required) — Bearer authentication header of the form `Bearer <PHONIC_API_KEY>`. Manage your API keys [here](https://phonic.co/api-keys).

## Request

### Path parameters

- `nameOrId` (string, required) — The name or the ID of the external storage policy to get.

### Query parameters

- `project` (string, optional, default: main) — The name of the project containing the external storage policy. Only used when `nameOrId` is a name.

## Response

### 200

Success response

- `external_storage_policy` (ExternalStoragePolicy, required) — An S3-compatible destination that conversation artifacts are delivered to.

## Errors

### 403 Forbidden Error

Forbidden (resource belongs to a different organization)

- `error` (BasicErrorError, optional)

### 404 Not Found Error

External storage policy not found

- `error` (BasicErrorError, optional)

### 500 Internal Server Error

Internal server error

- `error` (BasicErrorError, optional)

## Types

### ExternalStoragePolicy

An S3-compatible destination that conversation artifacts are delivered to.

- `id` (string, required) — The ID of the external storage policy.
- `name` (string, required) — The name of the external storage policy. Agents reference the policy by this name.
- `endpoint_url` (string, required) — The S3-compatible endpoint URL that artifacts are uploaded to.
- `bucket` (string, required) — The bucket that artifacts are uploaded to.
- `region` (string, required, nullable) — The region of the bucket. `null` when the endpoint doesn't require a region.
- `key_prefix` (string, required, nullable) — Prefix prepended to every object key. `null` when objects are written at the bucket root.
- `addressing_style` (enum, required, default: auto) — How bucket names are addressed in requests to the endpoint.
  - Allowed values: `auto`, `virtual`, `path`
- `agent_count` (integer, required) — Number of agents currently referencing this external storage policy.

### BasicErrorError

- `message` (string, required) — Error message
- `code` (string, optional) — Error code

## Examples

**Response**

```json
{
  "external_storage_policy": {
    "id": "external_storage_policy_9c5f7d2a-4b18-4d0e-8a2e-7a2f1c6d3b90",
    "name": "conversation_archive",
    "endpoint_url": "https://storage.example.com",
    "bucket": "conversation-audio",
    "region": "us-east-1",
    "key_prefix": "phonic/conversations",
    "addressing_style": "auto",
    "agent_count": 2
  }
}
```

**SDK Code**

```python Get external storage policy response
import requests

url = "https://api.phonic.ai/v1/external_storage_policies/nameOrId"

querystring = {"project":"main"}

headers = {"Authorization": "Bearer <apiKey>"}

response = requests.get(url, headers=headers, params=querystring)

print(response.json())
```

```javascript Get external storage policy response
const url = 'https://api.phonic.ai/v1/external_storage_policies/nameOrId?project=main';
const options = {method: 'GET', headers: {Authorization: 'Bearer <apiKey>'}};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go Get external storage policy response
package main

import (
	"fmt"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/external_storage_policies/nameOrId?project=main"

	req, _ := http.NewRequest("GET", url, nil)

	req.Header.Add("Authorization", "Bearer <apiKey>")

	res, _ := http.DefaultClient.Do(req)

	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)

	fmt.Println(res)
	fmt.Println(string(body))

}
```

```ruby Get external storage policy response
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/external_storage_policies/nameOrId?project=main")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Get.new(url)
request["Authorization"] = 'Bearer <apiKey>'

response = http.request(request)
puts response.read_body
```

```java Get external storage policy response
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.get("https://api.phonic.ai/v1/external_storage_policies/nameOrId?project=main")
  .header("Authorization", "Bearer <apiKey>")
  .asString();
```

```php Get external storage policy response
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('GET', 'https://api.phonic.ai/v1/external_storage_policies/nameOrId?project=main', [
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
  ],
]);

echo $response->getBody();
```

```csharp Get external storage policy response
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/external_storage_policies/nameOrId?project=main");
var request = new RestRequest(Method.GET);
request.AddHeader("Authorization", "Bearer <apiKey>");
IRestResponse response = client.Execute(request);
```

```swift Get external storage policy response
import Foundation

let headers = ["Authorization": "Bearer <apiKey>"]

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/external_storage_policies/nameOrId?project=main")! as URL,
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