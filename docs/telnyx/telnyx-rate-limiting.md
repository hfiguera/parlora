> ## Documentation Index
> Fetch the complete documentation index at: https://developers.telnyx.com/llms.txt
> Use this file to discover all available pages before exploring further.

# Telnyx API rate limiting

> Understand rate limits on the Telnyx REST API, including limit headers, retry strategies, and best practices for handling 429 responses across all services.

In order to protect our services, we employ the use of [rate limits](https://en.wikipedia.org/wiki/Rate_limiting) on the majority of `api.telnyx.com` endpoints. These limits are typically static, but are subject to change based on usage and may be adjusted to align with changes in capacity.

For this reason, we include headers in our API responses that should be parsed and respected by your application. These headers aim to help you understand your current consumption rate and self-diagnose or prevent potential throttling issues.

## Rate Limit Headers

| Term                  | Description                                                                      |
| --------------------- | -------------------------------------------------------------------------------- |
| x-ratelimit-limit     | Displays the applicable rate limits for the current request                      |
| x-ratelimit-remaining | Indicates how many requests a user can still make within the current time window |
| x-ratelimit-reset     | Shows the time in seconds until the rate limit resets                            |

When the rate limit is exceeded, responses with status code 429 will be returned,
indicating that you have exhausted the number of requests allowed in the current
window.

## Rate Limit Response

### HTTP Status Code

The status code of rate limit responses is [429](https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/429).

### Response Body

```json theme={null}
{
  "errors": [
    {
      "code": "10011",
      "title": "Too many requests",
      "detail": "You have exceeded the maximum number of allowed requests."
    }
  ]
}
```

## Handling Rate Limits

### Best Practices

1. **Monitor Headers**: Always check the rate limit headers in API responses
2. **Implement Backoff**: Use exponential backoff when receiving 429 responses
3. **Cache Results**: Cache API responses when possible to reduce request frequency
4. **Distribute Load**: Spread requests across multiple time windows

### Over Your Rate Limit?

Contact [support@telnyx.com](mailto:support@telnyx.com) if you find you are exceeding the rate limit.

## Product-Specific Rate Limits

Different Telnyx services may have different rate limiting strategies:

* **Messaging**: See [Rate Limiting](/docs/messaging/messages/rate-limiting) and [Message Encoding](/docs/messaging/messages/message-encoding) for messaging-specific limits
* **10DLC**: See [10DLC rate limits](/docs/messaging/10dlc/10dlc-rate-limits) for campaign-specific limits
* **Voice API**: Standard API rate limits apply to call control endpoints
* **Cloud Storage**: Rate limits apply to S3-compatible operations
