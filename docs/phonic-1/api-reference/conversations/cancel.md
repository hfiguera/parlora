> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Cancel

POST https://api.phonic.ai/v1/conversations/{id}/cancel

Cancels an active conversation.

Reference: https://docs.phonic.ai/api-reference/conversations/cancel

## Authentication

- `Authorization` header (bearer token, required) — Bearer authentication header of the form `Bearer <PHONIC_API_KEY>`. Manage your API keys [here](https://phonic.co/api-keys).

## Request

### Path parameters

- `id` (string, required) — The ID of the conversation to cancel.

## Response

### 200

Success response

- `success` (boolean, required) — Whether the conversation was cancelled successfully.

## Errors

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

Conversation already ended

- `Error`
  - BasicError: BasicError
  - ValidationError: ValidationError

### 500 Internal Server Error

Internal server error

- `error` (BasicErrorError, optional)

### 504 Gateway Timeout Error

Cancellation timeout

- `Error`
  - BasicError: BasicError
  - ValidationError: ValidationError

## Types

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
  "success": true
}
```

**SDK Code**

```python Cancel conversation response
import requests

url = "https://api.phonic.ai/v1/conversations/id/cancel"

headers = {"Authorization": "Bearer <apiKey>"}

response = requests.post(url, headers=headers)

print(response.json())
```

```javascript Cancel conversation response
const url = 'https://api.phonic.ai/v1/conversations/id/cancel';
const options = {method: 'POST', headers: {Authorization: 'Bearer <apiKey>'}};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go Cancel conversation response
package main

import (
	"fmt"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/conversations/id/cancel"

	req, _ := http.NewRequest("POST", url, nil)

	req.Header.Add("Authorization", "Bearer <apiKey>")

	res, _ := http.DefaultClient.Do(req)

	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)

	fmt.Println(res)
	fmt.Println(string(body))

}
```

```ruby Cancel conversation response
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/conversations/id/cancel")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Post.new(url)
request["Authorization"] = 'Bearer <apiKey>'

response = http.request(request)
puts response.read_body
```

```java Cancel conversation response
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.post("https://api.phonic.ai/v1/conversations/id/cancel")
  .header("Authorization", "Bearer <apiKey>")
  .asString();
```

```php Cancel conversation response
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('POST', 'https://api.phonic.ai/v1/conversations/id/cancel', [
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
  ],
]);

echo $response->getBody();
```

```csharp Cancel conversation response
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/conversations/id/cancel");
var request = new RestRequest(Method.POST);
request.AddHeader("Authorization", "Bearer <apiKey>");
IRestResponse response = client.Execute(request);
```

```swift Cancel conversation response
import Foundation

let headers = ["Authorization": "Bearer <apiKey>"]

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/conversations/id/cancel")! as URL,
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