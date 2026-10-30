> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# List Evaluations

GET https://api.phonic.ai/v1/conversations/{id}/evals

Returns all evaluations for a conversation.

Reference: https://docs.phonic.ai/api-reference/conversations/list-evaluations

## Authentication

- `Authorization` header (bearer token, required) — Bearer authentication header of the form `Bearer <PHONIC_API_KEY>`. Manage your API keys [here](https://phonic.co/api-keys).

## Request

### Path parameters

- `id` (string, required) — The ID of the conversation to get evaluations for.

## Response

### 200

Success response

- `evals` (list of ConversationEvaluationResult, required)

## Errors

### 401 Unauthorized Error

Unauthorized (authentication missing or invalid)

- `error` (BasicErrorError, optional)

### 403 Forbidden Error

Unauthorized

- `Error`
  - BasicError: BasicError
  - ValidationError: ValidationError

### 404 Not Found Error

Conversation not found

- `Error`
  - BasicError: BasicError
  - ValidationError: ValidationError

### 500 Internal Server Error

Internal server error

- `error` (BasicErrorError, optional)

## Types

### ConversationEvaluationResult

- `id` (string, required) — The evaluation ID.
- `result` (enum, required) — The evaluation result.
  - Allowed values: `successful`, `unsuccessful`, `undecided`, `error`
- `prompt` (ConversationEvaluationResultPrompt, required) — The evaluation prompt information.
- `created_at` (string, required) — When the evaluation was created.

### BasicErrorError

- `message` (string, required) — Error message
- `code` (string, optional) — Error code

### BasicError

- `error` (BasicErrorError, optional)

### ValidationError

- `error` (ValidationErrorError, required)
- `param_errors` (map from string to string, required) — Parameter-specific validation errors

### ConversationEvaluationResultPrompt

The evaluation prompt information.

- `id` (string, required)
- `name` (string, required)

### ValidationErrorError

- `message` (string, required) — Error message

## Examples

**Response**

```json
{
  "evals": [
    {
      "id": "conv_eval_12345678-abcd-efgh-ijkl-mnopqrstuvwx",
      "result": "successful",
      "prompt": {
        "id": "conv_eval_prompt_d7cfe45d-35db-4ef6-a254-81ab1da76ce0",
        "name": "chocolate_usage"
      },
      "created_at": "2025-07-30T23:49:18.130Z"
    }
  ]
}
```

**SDK Code**

```python Conversation evaluations response
import requests

url = "https://api.phonic.ai/v1/conversations/id/evals"

headers = {"Authorization": "Bearer <apiKey>"}

response = requests.get(url, headers=headers)

print(response.json())
```

```javascript Conversation evaluations response
const url = 'https://api.phonic.ai/v1/conversations/id/evals';
const options = {method: 'GET', headers: {Authorization: 'Bearer <apiKey>'}};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go Conversation evaluations response
package main

import (
	"fmt"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/conversations/id/evals"

	req, _ := http.NewRequest("GET", url, nil)

	req.Header.Add("Authorization", "Bearer <apiKey>")

	res, _ := http.DefaultClient.Do(req)

	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)

	fmt.Println(res)
	fmt.Println(string(body))

}
```

```ruby Conversation evaluations response
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/conversations/id/evals")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Get.new(url)
request["Authorization"] = 'Bearer <apiKey>'

response = http.request(request)
puts response.read_body
```

```java Conversation evaluations response
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.get("https://api.phonic.ai/v1/conversations/id/evals")
  .header("Authorization", "Bearer <apiKey>")
  .asString();
```

```php Conversation evaluations response
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('GET', 'https://api.phonic.ai/v1/conversations/id/evals', [
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
  ],
]);

echo $response->getBody();
```

```csharp Conversation evaluations response
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/conversations/id/evals");
var request = new RestRequest(Method.GET);
request.AddHeader("Authorization", "Bearer <apiKey>");
IRestResponse response = client.Execute(request);
```

```swift Conversation evaluations response
import Foundation

let headers = ["Authorization": "Bearer <apiKey>"]

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/conversations/id/evals")! as URL,
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