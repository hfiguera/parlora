> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Create

POST https://api.phonic.ai/v1/external_storage_policies
Content-Type: application/json

Creates a new external storage policy in a project. Agents referencing the policy deliver their conversation artifacts to the configured S3-compatible bucket.

Reference: https://docs.phonic.ai/api-reference/external-storage-policies/create

## Authentication

- `Authorization` header (bearer token, required) — Bearer authentication header of the form `Bearer <PHONIC_API_KEY>`. Manage your API keys [here](https://phonic.co/api-keys).

## Request

### Query parameters

- `project` (string, optional, default: main) — The name of the project to create the external storage policy in.

### Body (application/json)

This endpoint expects a CreateExternalStoragePolicyRequest.

- `name` (string, required) — The name of the external storage policy. Must be snake_case, start with a lowercase letter and be unique within the project.
- `endpoint_url` (string, required) — The S3-compatible endpoint URL that artifacts are uploaded to. Must be a publicly routable HTTPS URL without embedded credentials.
- `bucket` (string, required) — The bucket that artifacts are uploaded to.
- `access_key_id` (string, required) — Access key ID used to authenticate with the endpoint. Stored encrypted and never returned.
- `secret_access_key` (string, required) — Secret access key used to authenticate with the endpoint. Stored encrypted and never returned.
- `region` (string, optional, nullable) — The region of the bucket. Set to `null` when the endpoint doesn't require a region.
- `key_prefix` (string, optional, nullable) — Prefix prepended to every object key.
- `addressing_style` (enum, optional, default: auto) — How bucket names are addressed in requests to the endpoint.
  - Allowed values: `auto`, `virtual`, `path`

## Response

### 201

Success response

- `id` (string, required) — The ID of the created external storage policy.
- `name` (string, required) — The name of the created external storage policy.

## Errors

### 400 Bad Request Error

Invalid parameters

- `error` (ValidationErrorError, required)
- `param_errors` (map from string to string, required) — Parameter-specific validation errors

### 401 Unauthorized Error

Unauthorized (authentication missing or invalid)

- `error` (BasicErrorError, optional)

### 404 Not Found Error

Project not found

- `error` (BasicErrorError, optional)

### 409 Conflict Error

External storage policy name already exists

- `error` (ValidationErrorError, required)
- `param_errors` (map from string to string, required) — Parameter-specific validation errors

### 500 Internal Server Error

Internal server error

- `error` (BasicErrorError, optional)

## Types

### ValidationErrorError

- `message` (string, required) — Error message

### BasicErrorError

- `message` (string, required) — Error message
- `code` (string, optional) — Error code

## Examples

### Created external storage policy response

**Response**

```json
{
  "id": "external_storage_policy_9c5f7d2a-4b18-4d0e-8a2e-7a2f1c6d3b90",
  "name": "conversation_archive"
}
```

**SDK Code**

```python Created external storage policy response
import requests

url = "https://api.phonic.ai/v1/external_storage_policies"

querystring = {"project":"main"}

headers = {"Authorization": "Bearer <apiKey>"}

response = requests.post(url, headers=headers, params=querystring)

print(response.json())
```

```javascript Created external storage policy response
const url = 'https://api.phonic.ai/v1/external_storage_policies?project=main';
const options = {method: 'POST', headers: {Authorization: 'Bearer <apiKey>'}};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go Created external storage policy response
package main

import (
	"fmt"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/external_storage_policies?project=main"

	req, _ := http.NewRequest("POST", url, nil)

	req.Header.Add("Authorization", "Bearer <apiKey>")

	res, _ := http.DefaultClient.Do(req)

	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)

	fmt.Println(res)
	fmt.Println(string(body))

}
```

```ruby Created external storage policy response
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/external_storage_policies?project=main")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Post.new(url)
request["Authorization"] = 'Bearer <apiKey>'

response = http.request(request)
puts response.read_body
```

```java Created external storage policy response
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.post("https://api.phonic.ai/v1/external_storage_policies?project=main")
  .header("Authorization", "Bearer <apiKey>")
  .asString();
```

```php Created external storage policy response
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('POST', 'https://api.phonic.ai/v1/external_storage_policies?project=main', [
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
  ],
]);

echo $response->getBody();
```

```csharp Created external storage policy response
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/external_storage_policies?project=main");
var request = new RestRequest(Method.POST);
request.AddHeader("Authorization", "Bearer <apiKey>");
IRestResponse response = client.Execute(request);
```

```swift Created external storage policy response
import Foundation

let headers = ["Authorization": "Bearer <apiKey>"]

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/external_storage_policies?project=main")! as URL,
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

### external_storage_policies_create_example

**Request**

```json
{
  "name": "conversation_archive",
  "endpoint_url": "https://storage.example.com",
  "bucket": "conversation-audio",
  "access_key_id": "AKIAIOSFODNN7EXAMPLE",
  "secret_access_key": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
  "region": "us-east-1",
  "key_prefix": "phonic/conversations",
  "addressing_style": "auto"
}
```

**Response**

```json
{
  "id": "external_storage_policy_9c5f7d2a-4b18-4d0e-8a2e-7a2f1c6d3b90",
  "name": "conversation_archive"
}
```

**SDK Code**

```python external_storage_policies_create_example
import requests

url = "https://api.phonic.ai/v1/external_storage_policies"

querystring = {"project":"main"}

payload = {
    "name": "conversation_archive",
    "endpoint_url": "https://storage.example.com",
    "bucket": "conversation-audio",
    "access_key_id": "AKIAIOSFODNN7EXAMPLE",
    "secret_access_key": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    "region": "us-east-1",
    "key_prefix": "phonic/conversations",
    "addressing_style": "auto"
}
headers = {
    "Authorization": "Bearer <apiKey>",
    "Content-Type": "application/json"
}

response = requests.post(url, json=payload, headers=headers, params=querystring)

print(response.json())
```

```javascript external_storage_policies_create_example
const url = 'https://api.phonic.ai/v1/external_storage_policies?project=main';
const options = {
  method: 'POST',
  headers: {Authorization: 'Bearer <apiKey>', 'Content-Type': 'application/json'},
  body: '{"name":"conversation_archive","endpoint_url":"https://storage.example.com","bucket":"conversation-audio","access_key_id":"AKIAIOSFODNN7EXAMPLE","secret_access_key":"wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY","region":"us-east-1","key_prefix":"phonic/conversations","addressing_style":"auto"}'
};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go external_storage_policies_create_example
package main

import (
	"fmt"
	"strings"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/external_storage_policies?project=main"

	payload := strings.NewReader("{\n  \"name\": \"conversation_archive\",\n  \"endpoint_url\": \"https://storage.example.com\",\n  \"bucket\": \"conversation-audio\",\n  \"access_key_id\": \"AKIAIOSFODNN7EXAMPLE\",\n  \"secret_access_key\": \"wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\",\n  \"region\": \"us-east-1\",\n  \"key_prefix\": \"phonic/conversations\",\n  \"addressing_style\": \"auto\"\n}")

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

```ruby external_storage_policies_create_example
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/external_storage_policies?project=main")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Post.new(url)
request["Authorization"] = 'Bearer <apiKey>'
request["Content-Type"] = 'application/json'
request.body = "{\n  \"name\": \"conversation_archive\",\n  \"endpoint_url\": \"https://storage.example.com\",\n  \"bucket\": \"conversation-audio\",\n  \"access_key_id\": \"AKIAIOSFODNN7EXAMPLE\",\n  \"secret_access_key\": \"wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\",\n  \"region\": \"us-east-1\",\n  \"key_prefix\": \"phonic/conversations\",\n  \"addressing_style\": \"auto\"\n}"

response = http.request(request)
puts response.read_body
```

```java external_storage_policies_create_example
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.post("https://api.phonic.ai/v1/external_storage_policies?project=main")
  .header("Authorization", "Bearer <apiKey>")
  .header("Content-Type", "application/json")
  .body("{\n  \"name\": \"conversation_archive\",\n  \"endpoint_url\": \"https://storage.example.com\",\n  \"bucket\": \"conversation-audio\",\n  \"access_key_id\": \"AKIAIOSFODNN7EXAMPLE\",\n  \"secret_access_key\": \"wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\",\n  \"region\": \"us-east-1\",\n  \"key_prefix\": \"phonic/conversations\",\n  \"addressing_style\": \"auto\"\n}")
  .asString();
```

```php external_storage_policies_create_example
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('POST', 'https://api.phonic.ai/v1/external_storage_policies?project=main', [
  'body' => '{
  "name": "conversation_archive",
  "endpoint_url": "https://storage.example.com",
  "bucket": "conversation-audio",
  "access_key_id": "AKIAIOSFODNN7EXAMPLE",
  "secret_access_key": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
  "region": "us-east-1",
  "key_prefix": "phonic/conversations",
  "addressing_style": "auto"
}',
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
    'Content-Type' => 'application/json',
  ],
]);

echo $response->getBody();
```

```csharp external_storage_policies_create_example
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/external_storage_policies?project=main");
var request = new RestRequest(Method.POST);
request.AddHeader("Authorization", "Bearer <apiKey>");
request.AddHeader("Content-Type", "application/json");
request.AddParameter("application/json", "{\n  \"name\": \"conversation_archive\",\n  \"endpoint_url\": \"https://storage.example.com\",\n  \"bucket\": \"conversation-audio\",\n  \"access_key_id\": \"AKIAIOSFODNN7EXAMPLE\",\n  \"secret_access_key\": \"wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\",\n  \"region\": \"us-east-1\",\n  \"key_prefix\": \"phonic/conversations\",\n  \"addressing_style\": \"auto\"\n}", ParameterType.RequestBody);
IRestResponse response = client.Execute(request);
```

```swift external_storage_policies_create_example
import Foundation

let headers = [
  "Authorization": "Bearer <apiKey>",
  "Content-Type": "application/json"
]
let parameters = [
  "name": "conversation_archive",
  "endpoint_url": "https://storage.example.com",
  "bucket": "conversation-audio",
  "access_key_id": "AKIAIOSFODNN7EXAMPLE",
  "secret_access_key": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
  "region": "us-east-1",
  "key_prefix": "phonic/conversations",
  "addressing_style": "auto"
] as [String : Any]

let postData = JSONSerialization.data(withJSONObject: parameters, options: [])

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/external_storage_policies?project=main")! as URL,
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