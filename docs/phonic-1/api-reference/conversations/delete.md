> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Delete

DELETE https://api.phonic.ai/v1/conversations/{id}

Deletes a conversation, scheduling its transcripts and audio recordings for deletion. The conversation must have ended.

Reference: https://docs.phonic.ai/api-reference/conversations/delete

## Authentication

- `Authorization` header (bearer token, required) — Bearer authentication header of the form `Bearer <PHONIC_API_KEY>`. Manage your API keys [here](https://phonic.co/api-keys).

## Request

### Path parameters

- `id` (string, required) — The ID of the conversation to delete.

## Response

### 200

Success response

- `success` (boolean, required) — Whether the conversation was deleted successfully.

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

Cannot delete an active conversation

- `Error`
  - BasicError: BasicError
  - ValidationError: ValidationError

### 500 Internal Server Error

Internal server error

- `error` (BasicErrorError, optional)

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

```python Delete conversation response
import requests

url = "https://api.phonic.ai/v1/conversations/id"

headers = {"Authorization": "Bearer <apiKey>"}

response = requests.delete(url, headers=headers)

print(response.json())
```

```javascript Delete conversation response
const url = 'https://api.phonic.ai/v1/conversations/id';
const options = {method: 'DELETE', headers: {Authorization: 'Bearer <apiKey>'}};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go Delete conversation response
package main

import (
	"fmt"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/conversations/id"

	req, _ := http.NewRequest("DELETE", url, nil)

	req.Header.Add("Authorization", "Bearer <apiKey>")

	res, _ := http.DefaultClient.Do(req)

	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)

	fmt.Println(res)
	fmt.Println(string(body))

}
```

```ruby Delete conversation response
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/conversations/id")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Delete.new(url)
request["Authorization"] = 'Bearer <apiKey>'

response = http.request(request)
puts response.read_body
```

```java Delete conversation response
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.delete("https://api.phonic.ai/v1/conversations/id")
  .header("Authorization", "Bearer <apiKey>")
  .asString();
```

```php Delete conversation response
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('DELETE', 'https://api.phonic.ai/v1/conversations/id', [
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
  ],
]);

echo $response->getBody();
```

```csharp Delete conversation response
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/conversations/id");
var request = new RestRequest(Method.DELETE);
request.AddHeader("Authorization", "Bearer <apiKey>");
IRestResponse response = client.Execute(request);
```

```swift Delete conversation response
import Foundation

let headers = ["Authorization": "Bearer <apiKey>"]

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/conversations/id")! as URL,
                                        cachePolicy: .useProtocolCachePolicy,
                                    timeoutInterval: 10.0)
request.httpMethod = "DELETE"
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