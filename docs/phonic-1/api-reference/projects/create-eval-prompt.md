> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Create Eval Prompt

POST https://api.phonic.ai/v1/projects/{id}/conversation_eval_prompts
Content-Type: application/json

Creates a new conversation evaluation prompt for a project.

Reference: https://docs.phonic.ai/api-reference/projects/create-eval-prompt

## Authentication

- `Authorization` header (bearer token, required) — Bearer authentication header of the form `Bearer <PHONIC_API_KEY>`. Manage your API keys [here](https://phonic.co/api-keys).

## Request

### Path parameters

- `id` (string, required) — The ID of the project.

### Body (application/json)

This endpoint expects a CreateConversationEvalPromptRequest.

- `name` (string, required) — A useful name for referring to this prompt.
- `prompt` (string, required) — Actual evaluation prompt text to evaluate conversations with.

## Response

### 201

Success response

- `id` (string, required) — The ID of the created evaluation prompt.

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

### 404 Not Found Error

Project not found

- `Error`
  - BasicError: BasicError
  - ValidationError: ValidationError

### 500 Internal Server Error

Internal server error

- `error` (BasicErrorError, optional)

## Types

### ValidationErrorError

- `message` (string, required) — Error message

### BasicErrorError

- `message` (string, required) — Error message
- `code` (string, optional) — Error code

### BasicError

- `error` (BasicErrorError, optional)

### ValidationError

- `error` (ValidationErrorError, required)
- `param_errors` (map from string to string, required) — Parameter-specific validation errors

## Examples

### Created conversation evaluation prompt response

**Response**

```json
{
  "id": "conv_eval_prompt_c818e617-59f9-4f43-936e-ca8a794f9ccf"
}
```

**SDK Code**

```python Created conversation evaluation prompt response
import requests

url = "https://api.phonic.ai/v1/projects/id/conversation_eval_prompts"

headers = {"Authorization": "Bearer <apiKey>"}

response = requests.post(url, headers=headers)

print(response.json())
```

```javascript Created conversation evaluation prompt response
const url = 'https://api.phonic.ai/v1/projects/id/conversation_eval_prompts';
const options = {method: 'POST', headers: {Authorization: 'Bearer <apiKey>'}};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go Created conversation evaluation prompt response
package main

import (
	"fmt"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/projects/id/conversation_eval_prompts"

	req, _ := http.NewRequest("POST", url, nil)

	req.Header.Add("Authorization", "Bearer <apiKey>")

	res, _ := http.DefaultClient.Do(req)

	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)

	fmt.Println(res)
	fmt.Println(string(body))

}
```

```ruby Created conversation evaluation prompt response
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/projects/id/conversation_eval_prompts")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Post.new(url)
request["Authorization"] = 'Bearer <apiKey>'

response = http.request(request)
puts response.read_body
```

```java Created conversation evaluation prompt response
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.post("https://api.phonic.ai/v1/projects/id/conversation_eval_prompts")
  .header("Authorization", "Bearer <apiKey>")
  .asString();
```

```php Created conversation evaluation prompt response
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('POST', 'https://api.phonic.ai/v1/projects/id/conversation_eval_prompts', [
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
  ],
]);

echo $response->getBody();
```

```csharp Created conversation evaluation prompt response
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/projects/id/conversation_eval_prompts");
var request = new RestRequest(Method.POST);
request.AddHeader("Authorization", "Bearer <apiKey>");
IRestResponse response = client.Execute(request);
```

```swift Created conversation evaluation prompt response
import Foundation

let headers = ["Authorization": "Bearer <apiKey>"]

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/projects/id/conversation_eval_prompts")! as URL,
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

### projects_create_eval_prompt_example

**Request**

```json
{
  "name": "test_prompt",
  "prompt": "The assistant used the word chocolate in the conversation"
}
```

**Response**

```json
{
  "id": "conv_eval_prompt_c818e617-59f9-4f43-936e-ca8a794f9ccf"
}
```

**SDK Code**

```python projects_create_eval_prompt_example
import requests

url = "https://api.phonic.ai/v1/projects/id/conversation_eval_prompts"

payload = {
    "name": "test_prompt",
    "prompt": "The assistant used the word chocolate in the conversation"
}
headers = {
    "Authorization": "Bearer <apiKey>",
    "Content-Type": "application/json"
}

response = requests.post(url, json=payload, headers=headers)

print(response.json())
```

```javascript projects_create_eval_prompt_example
const url = 'https://api.phonic.ai/v1/projects/id/conversation_eval_prompts';
const options = {
  method: 'POST',
  headers: {Authorization: 'Bearer <apiKey>', 'Content-Type': 'application/json'},
  body: '{"name":"test_prompt","prompt":"The assistant used the word chocolate in the conversation"}'
};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go projects_create_eval_prompt_example
package main

import (
	"fmt"
	"strings"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/projects/id/conversation_eval_prompts"

	payload := strings.NewReader("{\n  \"name\": \"test_prompt\",\n  \"prompt\": \"The assistant used the word chocolate in the conversation\"\n}")

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

```ruby projects_create_eval_prompt_example
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/projects/id/conversation_eval_prompts")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Post.new(url)
request["Authorization"] = 'Bearer <apiKey>'
request["Content-Type"] = 'application/json'
request.body = "{\n  \"name\": \"test_prompt\",\n  \"prompt\": \"The assistant used the word chocolate in the conversation\"\n}"

response = http.request(request)
puts response.read_body
```

```java projects_create_eval_prompt_example
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.post("https://api.phonic.ai/v1/projects/id/conversation_eval_prompts")
  .header("Authorization", "Bearer <apiKey>")
  .header("Content-Type", "application/json")
  .body("{\n  \"name\": \"test_prompt\",\n  \"prompt\": \"The assistant used the word chocolate in the conversation\"\n}")
  .asString();
```

```php projects_create_eval_prompt_example
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('POST', 'https://api.phonic.ai/v1/projects/id/conversation_eval_prompts', [
  'body' => '{
  "name": "test_prompt",
  "prompt": "The assistant used the word chocolate in the conversation"
}',
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
    'Content-Type' => 'application/json',
  ],
]);

echo $response->getBody();
```

```csharp projects_create_eval_prompt_example
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/projects/id/conversation_eval_prompts");
var request = new RestRequest(Method.POST);
request.AddHeader("Authorization", "Bearer <apiKey>");
request.AddHeader("Content-Type", "application/json");
request.AddParameter("application/json", "{\n  \"name\": \"test_prompt\",\n  \"prompt\": \"The assistant used the word chocolate in the conversation\"\n}", ParameterType.RequestBody);
IRestResponse response = client.Execute(request);
```

```swift projects_create_eval_prompt_example
import Foundation

let headers = [
  "Authorization": "Bearer <apiKey>",
  "Content-Type": "application/json"
]
let parameters = [
  "name": "test_prompt",
  "prompt": "The assistant used the word chocolate in the conversation"
] as [String : Any]

let postData = JSONSerialization.data(withJSONObject: parameters, options: [])

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/projects/id/conversation_eval_prompts")! as URL,
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