> ## Documentation Index
> Fetch the complete documentation index at: https://developers.telnyx.com/llms.txt
> Use this file to discover all available pages before exploring further.

# Receiving Webhooks for Programmable Voice

> Receive Telnyx Programmable Voice webhooks to drive call flow in real time. Includes event types, payload structure, retries, and SDK examples.

When you send a Voice API command and receive a successful response (i.e. 200 OK), you can expect to receive a webhook. The webhook will be delivered to the primary URL specified on the Voice API Application associated with the call. If that URL does not resolve, or your application returns a non 200 OK response, the webhook will be delivered to the failover URL, if one has been specified.

In order to minimize webhook delivery time, Telnyx:

* does not enforce the order in which webhooks are delivered
* retries webhook delivery if your application does not respond within a certain time threshold.

As a result, you may encounter:

* out-of-order webhooks
* simultaneous (or near simultaneous) webhooks
* duplicate webhooks

Duplicate webhooks may cause your application to issue duplicate commands. You can instruct Telnyx to ignore duplicate commands by sending a `command_id` parameter as part of your commands. Commands with duplicate `command_id`s within 60 seconds will be ignored.

Webhooks contain a variety of ID fields which describe them and correlate them with calls.

## Example: Receiving a Webhook

When you place an incoming call to a number associated with your Voice API Application, you will receive a callback for the incoming call. It should look something like the JSON below:

```json theme={null}
{
  "data": {
    "record_type": "event",
    "event_type": "call.initiated",
    "id": "0ccc7b54-4df3-4bca-a65a-3da1ecc777f0",
    "occurred_at": "2018-02-02T22:25:27.521992Z",
    "payload": {
      "call_control_id": "d14dbcee-880b-11eb-8204-02420a0f7568",
      "connection_id": "7267xxxxxxxxxxxxxx",
      "call_leg_id": "d14dbcee-880b-11eb-8204-02420a0f7568",
      "call_session_id": "428c31b6-abf3-3bc1-b7f4-5013ef9657c1",
      "client_state": "aGF2ZSBhIG5pY2UgZGF5ID1d",
      "from": "+1-202-555-0133",
      "to": "+12025550131",
      "direction": "incoming",
      "state": "parked"
    }
  },
  "meta": {
    "attempt": 1,
    "delivered_to": "http://example.com/webhooks"
  }
}
```

<Callout type="info">
  After pasting the above content, Kindly check and remove any new line added
</Callout>

<table class="table">
  <tbody>
    <tr>
      <td>Field</td>
      <td>Value</td>
    </tr>

    <tr>
      <td>record\_type</td>
      <td>Description of the record.</td>
    </tr>

    <tr>
      <td>event\_type</td>
      <td>The type of event detected by the Telnyx system</td>
    </tr>

    <tr>
      <td>id</td>
      <td>unique id for the webhook</td>
    </tr>

    <tr>
      <td>occurred\_at</td>
      <td>ISO-8601 datetime of when event occured</td>
    </tr>

    <tr>
      <td>call\_control\_id</td>
      <td>call id used to issue commands via Voice API</td>
    </tr>

    <tr>
      <td>connection\_id</td>
      <td>Voice API App ID (formerly Telnyx connection ID) used in the call.</td>
    </tr>

    <tr>
      <td>call\_leg\_id</td>
      <td>ID that is unique to the call and can be used to correlate webhook events</td>
    </tr>

    <tr>
      <td>call\_session\_id</td>
      <td>ID that is unique to the call session and can be used to correlate webhook events. Call session is a group of related call legs that logically belong to the same phone call, e.g. an inbound and outbound leg of a transferred call.</td>
    </tr>

    <tr>
      <td>client\_state</td>
      <td>State received from a command</td>
    </tr>

    <tr>
      <td>from</td>
      <td>Number or SIP URI placing the call</td>
    </tr>

    <tr>
      <td>to</td>
      <td>Destination number or SIP URI of the call</td>
    </tr>

    <tr>
      <td>direction</td>
      <td>Whether the call is 'incoming' or 'outgoing'</td>
    </tr>

    <tr>
      <td>state</td>
      <td>Whether the call is in 'bridging' or 'parked' state</td>
    </tr>
  </tbody>
</table>
