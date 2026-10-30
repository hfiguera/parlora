> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Get Analysis

GET https://api.phonic.ai/v1/conversations/{id}/analysis

Returns an analysis of the specified conversation.

Reference: https://docs.phonic.ai/api-reference/conversations/get-analysis

## Authentication

- `Authorization` header (bearer token, required) — Bearer authentication header of the form `Bearer <PHONIC_API_KEY>`. Manage your API keys [here](https://phonic.co/api-keys).

## Request

### Path parameters

- `id` (string, required) — The ID of the conversation to analyze.

## Response

### 200

Success response

- `analysis` (ConversationAnalysis, required)

## Errors

### 401 Unauthorized Error

Unauthorized (authentication missing or invalid)

- `error` (BasicErrorError, optional)

### 403 Forbidden Error

Forbidden

- `error` (BasicErrorError, optional)

### 404 Not Found Error

Conversation not found

- `Error`
  - BasicError: BasicError
  - ValidationError: ValidationError

### 500 Internal Server Error

Internal server error

- `error` (BasicErrorError, optional)

## Types

### ConversationAnalysis

- `id` (string, required) — The ID of the conversation analysis.
- `latencies_ms` (list of double, required) — Latencies between turns in milliseconds.
- `interruptions_count` (integer, required) — Number of interruptions in the conversation.

### BasicErrorError

- `message` (string, required) — Error message
- `code` (string, optional) — Error code

### BasicError

- `error` (BasicErrorError, optional)

### ValidationError

- `error` (ValidationErrorError, required)
- `param_errors` (map from string to string, required) — Parameter-specific validation errors

### ValidationErrorError

- `message` (string, required) — Error message

## Examples

**Response**

```json
{
  "analysis": {
    "id": "string",
    "latencies_ms": [
      456,
      654,
      564
    ],
    "interruptions_count": 2
  }
}
```

**SDK Code**

```python Conversation analysis response
import requests

url = "https://api.phonic.ai/v1/conversations/id/analysis"

headers = {"Authorization": "Bearer <apiKey>"}

response = requests.get(url, headers=headers)

print(response.json())
```

```javascript Conversation analysis response
const url = 'https://api.phonic.ai/v1/conversations/id/analysis';
const options = {method: 'GET', headers: {Authorization: 'Bearer <apiKey>'}};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go Conversation analysis response
package main

import (
	"fmt"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/conversations/id/analysis"

	req, _ := http.NewRequest("GET", url, nil)

	req.Header.Add("Authorization", "Bearer <apiKey>")

	res, _ := http.DefaultClient.Do(req)

	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)

	fmt.Println(res)
	fmt.Println(string(body))

}
```

```ruby Conversation analysis response
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/conversations/id/analysis")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Get.new(url)
request["Authorization"] = 'Bearer <apiKey>'

response = http.request(request)
puts response.read_body
```

```java Conversation analysis response
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.get("https://api.phonic.ai/v1/conversations/id/analysis")
  .header("Authorization", "Bearer <apiKey>")
  .asString();
```

```php Conversation analysis response
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('GET', 'https://api.phonic.ai/v1/conversations/id/analysis', [
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
  ],
]);

echo $response->getBody();
```

```csharp Conversation analysis response
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/conversations/id/analysis");
var request = new RestRequest(Method.GET);
request.AddHeader("Authorization", "Bearer <apiKey>");
IRestResponse response = client.Execute(request);
```

```swift Conversation analysis response
import Foundation

let headers = ["Authorization": "Bearer <apiKey>"]

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/conversations/id/analysis")! as URL,
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