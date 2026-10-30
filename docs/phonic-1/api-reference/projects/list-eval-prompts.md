> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# List Eval Prompts

GET https://api.phonic.ai/v1/projects/{id}/conversation_eval_prompts

Returns all conversation evaluation prompts for a project.

Reference: https://docs.phonic.ai/api-reference/projects/list-eval-prompts

## Authentication

- `Authorization` header (bearer token, required) — Bearer authentication header of the form `Bearer <PHONIC_API_KEY>`. Manage your API keys [here](https://phonic.co/api-keys).

## Request

### Path parameters

- `id` (string, required) — The ID of the project.

## Response

### 200

Success response

- `conversation_eval_prompts` (list of ConversationEvalPrompt, required)

## Errors

### 401 Unauthorized Error

Unauthorized (authentication missing or invalid)

- `error` (BasicErrorError, optional)

### 403 Forbidden Error

Forbidden

- `error` (BasicErrorError, optional)

### 404 Not Found Error

Project not found

- `Error`
  - BasicError: BasicError
  - ValidationError: ValidationError

### 500 Internal Server Error

Internal server error

- `error` (BasicErrorError, optional)

## Types

### ConversationEvalPrompt

- `id` (string, required) — The evaluation prompt ID.
- `name` (string, required) — The evaluation prompt name.
- `prompt` (string, required) — The evaluation prompt text.

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
  "conversation_eval_prompts": [
    {
      "id": "conv_eval_prompt_d7cfe45d-35db-4ef6-a254-81ab1da76ce0",
      "name": "chocolate_usage",
      "prompt": "The assistant used the word chocolate in the conversation"
    }
  ]
}
```

**SDK Code**

```python Conversation evaluation prompts response
import requests

url = "https://api.phonic.ai/v1/projects/id/conversation_eval_prompts"

headers = {"Authorization": "Bearer <apiKey>"}

response = requests.get(url, headers=headers)

print(response.json())
```

```javascript Conversation evaluation prompts response
const url = 'https://api.phonic.ai/v1/projects/id/conversation_eval_prompts';
const options = {method: 'GET', headers: {Authorization: 'Bearer <apiKey>'}};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go Conversation evaluation prompts response
package main

import (
	"fmt"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/projects/id/conversation_eval_prompts"

	req, _ := http.NewRequest("GET", url, nil)

	req.Header.Add("Authorization", "Bearer <apiKey>")

	res, _ := http.DefaultClient.Do(req)

	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)

	fmt.Println(res)
	fmt.Println(string(body))

}
```

```ruby Conversation evaluation prompts response
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/projects/id/conversation_eval_prompts")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Get.new(url)
request["Authorization"] = 'Bearer <apiKey>'

response = http.request(request)
puts response.read_body
```

```java Conversation evaluation prompts response
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.get("https://api.phonic.ai/v1/projects/id/conversation_eval_prompts")
  .header("Authorization", "Bearer <apiKey>")
  .asString();
```

```php Conversation evaluation prompts response
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('GET', 'https://api.phonic.ai/v1/projects/id/conversation_eval_prompts', [
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
  ],
]);

echo $response->getBody();
```

```csharp Conversation evaluation prompts response
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/projects/id/conversation_eval_prompts");
var request = new RestRequest(Method.GET);
request.AddHeader("Authorization", "Bearer <apiKey>");
IRestResponse response = client.Execute(request);
```

```swift Conversation evaluation prompts response
import Foundation

let headers = ["Authorization": "Bearer <apiKey>"]

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/projects/id/conversation_eval_prompts")! as URL,
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