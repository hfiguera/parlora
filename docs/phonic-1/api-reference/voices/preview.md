> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Preview

POST https://api.phonic.ai/v1/tts
Content-Type: application/json

Generates speech audio for the provided text and returns it as a single base64-encoded string.

Reference: https://docs.phonic.ai/api-reference/voices/preview

## Authentication

- `Authorization` header (bearer token, required) — Bearer authentication header of the form `Bearer <PHONIC_API_KEY>`. Manage your API keys [here](https://phonic.co/api-keys).

## Request

### Body (application/json)

This endpoint expects a StreamTtsRequest.

- `text` (string, required) — The text to convert to speech.
- `model` (enum, optional, default: merritt) — The TTS model to use.
  - Allowed values: `merritt`
- `speed` (double, optional, default: 1.2) — The speech speed.
- `voice_id` (string, optional, default: sabrina) — The voice ID to use.
- `output_format` (enum, optional, default: pcm_44100) — The audio format to stream.
  - Allowed values: `pcm_44100`, `pcm_24000`, `pcm_16000`, `pcm_8000`, `mulaw_8000`
- `languages` (list of enum, optional, default: []) — Candidate languages for synthesis. An empty array defaults to English, one language selects it directly, and multiple languages let Phonic detect among those candidates.
  - Allowed values: `ar`, `az`, `bg`, `bn`, `cs`, `da`, `de`, `el`, `en`, `es`, `fa`, `fi`, `fil`, `fr`, `gu`, `he`, `hi`, `hu`, `id`, `it`, `ja`, `ka`, `km`, `kn`, `ko`, `lt`, `lv`, `ml`, `mr`, `ms`, `ne`, `nl`, `no`, `pa`, `pl`, `pt`, `ro`, `ru`, `si`, `sk`, `sq`, `sv`, `sw`, `ta`, `te`, `th`, `tr`, `uk`, `ur`, `vi`, `yue`, `zh`

## Response

### 200

The generated audio.

- `audio` (string, required) — The generated speech, base64-encoded in the requested `output_format`.

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

**Request**

```json
{
  "text": "Thanks for calling Phonic. How can I help?",
  "voice_id": "grant",
  "output_format": "pcm_16000"
}
```

**Response**

```json
{
  "audio": "string"
}
```

**SDK Code**

```python voices_preview_example
import requests

url = "https://api.phonic.ai/v1/tts"

payload = {
    "text": "Thanks for calling Phonic. How can I help?",
    "voice_id": "grant",
    "output_format": "pcm_16000"
}
headers = {
    "Authorization": "Bearer <apiKey>",
    "Content-Type": "application/json"
}

response = requests.post(url, json=payload, headers=headers)

print(response.json())
```

```javascript voices_preview_example
const url = 'https://api.phonic.ai/v1/tts';
const options = {
  method: 'POST',
  headers: {Authorization: 'Bearer <apiKey>', 'Content-Type': 'application/json'},
  body: '{"text":"Thanks for calling Phonic. How can I help?","voice_id":"grant","output_format":"pcm_16000"}'
};

try {
  const response = await fetch(url, options);
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

```go voices_preview_example
package main

import (
	"fmt"
	"strings"
	"net/http"
	"io"
)

func main() {

	url := "https://api.phonic.ai/v1/tts"

	payload := strings.NewReader("{\n  \"text\": \"Thanks for calling Phonic. How can I help?\",\n  \"voice_id\": \"grant\",\n  \"output_format\": \"pcm_16000\"\n}")

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

```ruby voices_preview_example
require 'uri'
require 'net/http'

url = URI("https://api.phonic.ai/v1/tts")

http = Net::HTTP.new(url.host, url.port)
http.use_ssl = true

request = Net::HTTP::Post.new(url)
request["Authorization"] = 'Bearer <apiKey>'
request["Content-Type"] = 'application/json'
request.body = "{\n  \"text\": \"Thanks for calling Phonic. How can I help?\",\n  \"voice_id\": \"grant\",\n  \"output_format\": \"pcm_16000\"\n}"

response = http.request(request)
puts response.read_body
```

```java voices_preview_example
import com.mashape.unirest.http.HttpResponse;
import com.mashape.unirest.http.Unirest;

HttpResponse<String> response = Unirest.post("https://api.phonic.ai/v1/tts")
  .header("Authorization", "Bearer <apiKey>")
  .header("Content-Type", "application/json")
  .body("{\n  \"text\": \"Thanks for calling Phonic. How can I help?\",\n  \"voice_id\": \"grant\",\n  \"output_format\": \"pcm_16000\"\n}")
  .asString();
```

```php voices_preview_example
<?php
require_once('vendor/autoload.php');

$client = new \GuzzleHttp\Client();

$response = $client->request('POST', 'https://api.phonic.ai/v1/tts', [
  'body' => '{
  "text": "Thanks for calling Phonic. How can I help?",
  "voice_id": "grant",
  "output_format": "pcm_16000"
}',
  'headers' => [
    'Authorization' => 'Bearer <apiKey>',
    'Content-Type' => 'application/json',
  ],
]);

echo $response->getBody();
```

```csharp voices_preview_example
using RestSharp;

var client = new RestClient("https://api.phonic.ai/v1/tts");
var request = new RestRequest(Method.POST);
request.AddHeader("Authorization", "Bearer <apiKey>");
request.AddHeader("Content-Type", "application/json");
request.AddParameter("application/json", "{\n  \"text\": \"Thanks for calling Phonic. How can I help?\",\n  \"voice_id\": \"grant\",\n  \"output_format\": \"pcm_16000\"\n}", ParameterType.RequestBody);
IRestResponse response = client.Execute(request);
```

```swift voices_preview_example
import Foundation

let headers = [
  "Authorization": "Bearer <apiKey>",
  "Content-Type": "application/json"
]
let parameters = [
  "text": "Thanks for calling Phonic. How can I help?",
  "voice_id": "grant",
  "output_format": "pcm_16000"
] as [String : Any]

let postData = JSONSerialization.data(withJSONObject: parameters, options: [])

let request = NSMutableURLRequest(url: NSURL(string: "https://api.phonic.ai/v1/tts")! as URL,
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