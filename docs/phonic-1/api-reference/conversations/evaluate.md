> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Evaluate

POST https://api.phonic.ai/v1/conversations/{id}/evals
Content-Type: application/json

Evaluates a conversation using an evaluation prompt.

Reference: https://docs.phonic.ai/api-reference/conversations/evaluate

## Authentication

- `Authorization` header (bearer token, required) — Bearer authentication header of the form `Bearer <PHONIC_API_KEY>`. Manage your API keys [here](https://phonic.co/api-keys).

## Request

### Path parameters

- `id` (string, required) — The ID of the conversation to evaluate.

### Body (application/json)

This endpoint expects an EvaluateConversationRequest.

- `prompt_id` (string, required) — ID of the evaluation prompt to use.

## Response

### 201

Success response

- `evaluation` (ConversationsIdEvalsPostResponsesContentApplicationJsonSchemaEvaluation, required)

## Errors

### 400 Bad Request Error

Invalid parameters

- `Error`
  - BasicError: BasicError
  - ValidationError: ValidationError

### 401 Unauthorized Error

Unauthorized (authentication missing or invalid)

- `error` (BasicErrorError, optional)

### 403 Forbidden Error

Unauthorized

- `Error`
  - BasicError: BasicError
  - ValidationError: ValidationError

### 404 Not Found Error

Conversation or evaluation prompt not found

- `Error`
  - BasicError: BasicError
  - ValidationError: ValidationError

### 500 Internal Server Error

Internal server error

- `error` (BasicErrorError, optional)

## Types

### ConversationsIdEvalsPostResponsesContentApplicationJsonSchemaEvaluation

- `result` (enum, required) — The evaluation result.
  - Allowed values: `successful`, `unsuccessful`, `undecided`, `error`

### BasicError

- `error` (BasicErrorError, optional)

### ValidationError

- `error` (ValidationErrorError, required)
- `param_errors` (map from string to string, required) — Parameter-specific validation errors

### BasicErrorError

- `message` (string, required) — Error message
- `code` (string, optional) — Error code

### ValidationErrorError

- `message` (string, required) — Error message

## Examples

### Conversation evaluation result

**Response**

```json
{
  "evaluation": {
    "result": "successful"
  }
}
```

**SDK Code**

```python Conversation evaluation result
import requests

url = "https://api.phonic.ai/v1/conversations/id/evals"

headers = {"Authorization": "Bearer <apiKey>"}

response = requests.post(url, headers=headers)

print(response.json())
```

```javascript Conversation evaluation result
const url = 'https://api.phonic.ai/v1/conversations/id/evals';
const options = {method: 'POST', headers: {Authorization: 'Bearer <apiKey>'}};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go Conversation evaluation result
package main

import (
	"fmt"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/conversations/id/evals"

	req, _ := http.NewRequest("POST", url, nil)

	req.Header.Add("Authorization", "Bearer <apiKey>")

	res, _ := http.DefaultClient.Do(req)

	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)

	fmt.Println(res)
	fmt.Println(string(body))

}
```

```ruby Conversation evaluation result
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/conversations/id/evals")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Post.new(url)
request["Authorization"] = 'Bearer <apiKey>'

response = http.request(request)
puts response.read_body
```

```java Conversation evaluation result
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.post("https://api.phonic.ai/v1/conversations/id/evals")
  .header("Authorization", "Bearer <apiKey>")
  .asString();
```

```php Conversation evaluation result
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('POST', 'https://api.phonic.ai/v1/conversations/id/evals', [
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
  ],
]);

echo $response->getBody();
```

```csharp Conversation evaluation result
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/conversations/id/evals");
var request = new RestRequest(Method.POST);
request.AddHeader("Authorization", "Bearer <apiKey>");
IRestResponse response = client.Execute(request);
```

```swift Conversation evaluation result
import Foundation

let headers = ["Authorization": "Bearer <apiKey>"]

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/conversations/id/evals")! as URL,
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

### conversations_evaluate_example

**Request**

```json
{
  "prompt_id": "conv_eval_prompt_d7cfe45d-35db-4ef6-a254-81ab1da76ce0"
}
```

**Response**

```json
{
  "evaluation": {
    "result": "successful"
  }
}
```

**SDK Code**

```python conversations_evaluate_example
import requests

url = "https://api.phonic.ai/v1/conversations/id/evals"

payload = { "prompt_id": "conv_eval_prompt_d7cfe45d-35db-4ef6-a254-81ab1da76ce0" }
headers = {
    "Authorization": "Bearer <apiKey>",
    "Content-Type": "application/json"
}

response = requests.post(url, json=payload, headers=headers)

print(response.json())
```

```javascript conversations_evaluate_example
const url = 'https://api.phonic.ai/v1/conversations/id/evals';
const options = {
  method: 'POST',
  headers: {Authorization: 'Bearer <apiKey>', 'Content-Type': 'application/json'},
  body: '{"prompt_id":"conv_eval_prompt_d7cfe45d-35db-4ef6-a254-81ab1da76ce0"}'
};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go conversations_evaluate_example
package main

import (
	"fmt"
	"strings"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/conversations/id/evals"

	payload := strings.NewReader("{\n  \"prompt_id\": \"conv_eval_prompt_d7cfe45d-35db-4ef6-a254-81ab1da76ce0\"\n}")

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

```ruby conversations_evaluate_example
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/conversations/id/evals")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Post.new(url)
request["Authorization"] = 'Bearer <apiKey>'
request["Content-Type"] = 'application/json'
request.body = "{\n  \"prompt_id\": \"conv_eval_prompt_d7cfe45d-35db-4ef6-a254-81ab1da76ce0\"\n}"

response = http.request(request)
puts response.read_body
```

```java conversations_evaluate_example
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.post("https://api.phonic.ai/v1/conversations/id/evals")
  .header("Authorization", "Bearer <apiKey>")
  .header("Content-Type", "application/json")
  .body("{\n  \"prompt_id\": \"conv_eval_prompt_d7cfe45d-35db-4ef6-a254-81ab1da76ce0\"\n}")
  .asString();
```

```php conversations_evaluate_example
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('POST', 'https://api.phonic.ai/v1/conversations/id/evals', [
  'body' => '{
  "prompt_id": "conv_eval_prompt_d7cfe45d-35db-4ef6-a254-81ab1da76ce0"
}',
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
    'Content-Type' => 'application/json',
  ],
]);

echo $response->getBody();
```

```csharp conversations_evaluate_example
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/conversations/id/evals");
var request = new RestRequest(Method.POST);
request.AddHeader("Authorization", "Bearer <apiKey>");
request.AddHeader("Content-Type", "application/json");
request.AddParameter("application/json", "{\n  \"prompt_id\": \"conv_eval_prompt_d7cfe45d-35db-4ef6-a254-81ab1da76ce0\"\n}", ParameterType.RequestBody);
IRestResponse response = client.Execute(request);
```

```swift conversations_evaluate_example
import Foundation

let headers = [
  "Authorization": "Bearer <apiKey>",
  "Content-Type": "application/json"
]
let parameters = ["prompt_id": "conv_eval_prompt_d7cfe45d-35db-4ef6-a254-81ab1da76ce0"] as [String : Any]

let postData = JSONSerialization.data(withJSONObject: parameters, options: [])

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/conversations/id/evals")! as URL,
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