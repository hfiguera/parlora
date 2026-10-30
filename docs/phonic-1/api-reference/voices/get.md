> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Get

GET https://api.phonic.ai/v1/voices/{id}

Returns a voice by ID.

Reference: https://docs.phonic.ai/api-reference/voices/get

## Authentication

- `Authorization` header (bearer token, required) — Bearer authentication header of the form `Bearer <PHONIC_API_KEY>`. Manage your API keys [here](https://phonic.co/api-keys).

## Request

### Path parameters

- `id` (string, required) — The ID of the voice to get.

## Response

### 200

Success response

- `voice` (Voice, required)

## Errors

### 401 Unauthorized Error

Unauthorized (authentication missing or invalid)

- `error` (BasicErrorError, optional)

### 404 Not Found Error

Voice not found

- `Error`
  - BasicError: BasicError
  - ValidationError: ValidationError

## Types

### Voice

- `id` (string, required) — The voice ID.
- `name` (string, required) — The voice name.
- `description` (string, required, nullable) — The voice description.
- `audio_url` (string, required) — Presigned URL to the voice sample audio file. Expires in 7 days.

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
  "voice": {
    "id": "sabrina",
    "name": "Sabrina",
    "description": null,
    "audio_url": "https://example.com/audio/sabrina.wav"
  }
}
```

**SDK Code**

```python Get voice response
import requests

url = "https://api.phonic.ai/v1/voices/id"

headers = {"Authorization": "Bearer <apiKey>"}

response = requests.get(url, headers=headers)

print(response.json())
```

```javascript Get voice response
const url = 'https://api.phonic.ai/v1/voices/id';
const options = {method: 'GET', headers: {Authorization: 'Bearer <apiKey>'}};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go Get voice response
package main

import (
	"fmt"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/voices/id"

	req, _ := http.NewRequest("GET", url, nil)

	req.Header.Add("Authorization", "Bearer <apiKey>")

	res, _ := http.DefaultClient.Do(req)

	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)

	fmt.Println(res)
	fmt.Println(string(body))

}
```

```ruby Get voice response
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/voices/id")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Get.new(url)
request["Authorization"] = 'Bearer <apiKey>'

response = http.request(request)
puts response.read_body
```

```java Get voice response
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.get("https://api.phonic.ai/v1/voices/id")
  .header("Authorization", "Bearer <apiKey>")
  .asString();
```

```php Get voice response
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('GET', 'https://api.phonic.ai/v1/voices/id', [
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
  ],
]);

echo $response->getBody();
```

```csharp Get voice response
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/voices/id");
var request = new RestRequest(Method.GET);
request.AddHeader("Authorization", "Bearer <apiKey>");
IRestResponse response = client.Execute(request);
```

```swift Get voice response
import Foundation

let headers = ["Authorization": "Bearer <apiKey>"]

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/voices/id")! as URL,
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