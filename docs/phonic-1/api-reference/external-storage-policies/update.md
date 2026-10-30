> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Update

PATCH https://api.phonic.ai/v1/external_storage_policies/{nameOrId}
Content-Type: application/json

Updates an external storage policy by name or ID. Credentials can only be rotated by providing both `access_key_id` and `secret_access_key`.

Reference: https://docs.phonic.ai/api-reference/external-storage-policies/update

## Authentication

- `Authorization` header (bearer token, required) — Bearer authentication header of the form `Bearer <PHONIC_API_KEY>`. Manage your API keys [here](https://phonic.co/api-keys).

## Request

### Path parameters

- `nameOrId` (string, required) — The name or the ID of the external storage policy to update.

### Query parameters

- `project` (string, optional, default: main) — The name of the project containing the external storage policy. Only used when `nameOrId` is a name.

### Body (application/json)

This endpoint expects an UpdateExternalStoragePolicyRequest.

- `name` (string, optional) — The name of the external storage policy. Must be snake_case, start with a lowercase letter and be unique within the project.
- `endpoint_url` (string, optional) — The S3-compatible endpoint URL that artifacts are uploaded to. Must be a publicly routable HTTPS URL without embedded credentials.
- `bucket` (string, optional) — The bucket that artifacts are uploaded to.
- `region` (string, optional, nullable) — The region of the bucket. Set to `null` when the endpoint doesn't require a region.
- `key_prefix` (string, optional, nullable) — Prefix prepended to every object key.
- `addressing_style` (enum, optional) — How bucket names are addressed in requests to the endpoint.
  - Allowed values: `auto`, `virtual`, `path`
- `access_key_id` (string, optional) — Access key ID used to authenticate with the endpoint. Must be provided together with `secret_access_key`.
- `secret_access_key` (string, optional) — Secret access key used to authenticate with the endpoint. Must be provided together with `access_key_id`.

## Response

### 200

Success response

- `success` (boolean, required) — Whether the external storage policy was updated successfully.

## Errors

### 400 Bad Request Error

Invalid parameters

- `error` (ValidationErrorError, required)
- `param_errors` (map from string to string, required) — Parameter-specific validation errors

### 401 Unauthorized Error

Unauthorized (authentication missing or invalid)

- `error` (BasicErrorError, optional)

### 403 Forbidden Error

Forbidden (resource belongs to a different organization)

- `error` (BasicErrorError, optional)

### 404 Not Found Error

External storage policy not found

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

### Update external storage policy response

**Response**

```json
{
  "success": true
}
```

**SDK Code**

```python Update external storage policy response
import requests

url = "https://api.phonic.ai/v1/external_storage_policies/nameOrId"

querystring = {"project":"main"}

headers = {"Authorization": "Bearer <apiKey>"}

response = requests.patch(url, headers=headers, params=querystring)

print(response.json())
```

```javascript Update external storage policy response
const url = 'https://api.phonic.ai/v1/external_storage_policies/nameOrId?project=main';
const options = {method: 'PATCH', headers: {Authorization: 'Bearer <apiKey>'}};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go Update external storage policy response
package main

import (
	"fmt"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/external_storage_policies/nameOrId?project=main"

	req, _ := http.NewRequest("PATCH", url, nil)

	req.Header.Add("Authorization", "Bearer <apiKey>")

	res, _ := http.DefaultClient.Do(req)

	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)

	fmt.Println(res)
	fmt.Println(string(body))

}
```

```ruby Update external storage policy response
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/external_storage_policies/nameOrId?project=main")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Patch.new(url)
request["Authorization"] = 'Bearer <apiKey>'

response = http.request(request)
puts response.read_body
```

```java Update external storage policy response
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.patch("https://api.phonic.ai/v1/external_storage_policies/nameOrId?project=main")
  .header("Authorization", "Bearer <apiKey>")
  .asString();
```

```php Update external storage policy response
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('PATCH', 'https://api.phonic.ai/v1/external_storage_policies/nameOrId?project=main', [
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
  ],
]);

echo $response->getBody();
```

```csharp Update external storage policy response
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/external_storage_policies/nameOrId?project=main");
var request = new RestRequest(Method.PATCH);
request.AddHeader("Authorization", "Bearer <apiKey>");
IRestResponse response = client.Execute(request);
```

```swift Update external storage policy response
import Foundation

let headers = ["Authorization": "Bearer <apiKey>"]

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/external_storage_policies/nameOrId?project=main")! as URL,
                                        cachePolicy: .useProtocolCachePolicy,
                                    timeoutInterval: 10.0)
request.httpMethod = "PATCH"
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

### external_storage_policies_update_example

**Request**

```json
{
  "bucket": "conversation-audio-archive",
  "key_prefix": "phonic/archive"
}
```

**Response**

```json
{
  "success": true
}
```

**SDK Code**

```python external_storage_policies_update_example
import requests

url = "https://api.phonic.ai/v1/external_storage_policies/nameOrId"

querystring = {"project":"main"}

payload = {
    "bucket": "conversation-audio-archive",
    "key_prefix": "phonic/archive"
}
headers = {
    "Authorization": "Bearer <apiKey>",
    "Content-Type": "application/json"
}

response = requests.patch(url, json=payload, headers=headers, params=querystring)

print(response.json())
```

```javascript external_storage_policies_update_example
const url = 'https://api.phonic.ai/v1/external_storage_policies/nameOrId?project=main';
const options = {
  method: 'PATCH',
  headers: {Authorization: 'Bearer <apiKey>', 'Content-Type': 'application/json'},
  body: '{"bucket":"conversation-audio-archive","key_prefix":"phonic/archive"}'
};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go external_storage_policies_update_example
package main

import (
	"fmt"
	"strings"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/external_storage_policies/nameOrId?project=main"

	payload := strings.NewReader("{\n  \"bucket\": \"conversation-audio-archive\",\n  \"key_prefix\": \"phonic/archive\"\n}")

	req, _ := http.NewRequest("PATCH", url, payload)

	req.Header.Add("Authorization", "Bearer <apiKey>")
	req.Header.Add("Content-Type", "application/json")

	res, _ := http.DefaultClient.Do(req)

	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)

	fmt.Println(res)
	fmt.Println(string(body))

}
```

```ruby external_storage_policies_update_example
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/external_storage_policies/nameOrId?project=main")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Patch.new(url)
request["Authorization"] = 'Bearer <apiKey>'
request["Content-Type"] = 'application/json'
request.body = "{\n  \"bucket\": \"conversation-audio-archive\",\n  \"key_prefix\": \"phonic/archive\"\n}"

response = http.request(request)
puts response.read_body
```

```java external_storage_policies_update_example
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.patch("https://api.phonic.ai/v1/external_storage_policies/nameOrId?project=main")
  .header("Authorization", "Bearer <apiKey>")
  .header("Content-Type", "application/json")
  .body("{\n  \"bucket\": \"conversation-audio-archive\",\n  \"key_prefix\": \"phonic/archive\"\n}")
  .asString();
```

```php external_storage_policies_update_example
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('PATCH', 'https://api.phonic.ai/v1/external_storage_policies/nameOrId?project=main', [
  'body' => '{
  "bucket": "conversation-audio-archive",
  "key_prefix": "phonic/archive"
}',
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
    'Content-Type' => 'application/json',
  ],
]);

echo $response->getBody();
```

```csharp external_storage_policies_update_example
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/external_storage_policies/nameOrId?project=main");
var request = new RestRequest(Method.PATCH);
request.AddHeader("Authorization", "Bearer <apiKey>");
request.AddHeader("Content-Type", "application/json");
request.AddParameter("application/json", "{\n  \"bucket\": \"conversation-audio-archive\",\n  \"key_prefix\": \"phonic/archive\"\n}", ParameterType.RequestBody);
IRestResponse response = client.Execute(request);
```

```swift external_storage_policies_update_example
import Foundation

let headers = [
  "Authorization": "Bearer <apiKey>",
  "Content-Type": "application/json"
]
let parameters = [
  "bucket": "conversation-audio-archive",
  "key_prefix": "phonic/archive"
] as [String : Any]

let postData = JSONSerialization.data(withJSONObject: parameters, options: [])

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/external_storage_policies/nameOrId?project=main")! as URL,
                                        cachePolicy: .useProtocolCachePolicy,
                                    timeoutInterval: 10.0)
request.httpMethod = "PATCH"
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