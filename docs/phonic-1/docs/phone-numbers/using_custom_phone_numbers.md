> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# SIP Trunk (Twilio, Telnyx)

> Learn how to use your Phonic Voice Agent to send and receive calls to custom phone number via SIP trunking

There are two regimes in which the Phonic Voice Agent can communicate over telephone:

* Outbound Calls: The agent is the *caller*. The agent initiates calls to other phone numbers from a user-configured phone number.
* Inbound Calls: The agent is the *callee*. The agent receives calls from anyone at a user-configured phone number.

Phonic provides an easy way to use Phonic's reserved phone numbers for performing both [inbound](/api-reference/agents/create) and [outbound](/api-reference/conversations/outbound_call) calls. This guide is for configuring your own phone number with a SIP trunking provider like [Twilio](https://www.twilio.com/docs/sip-trunking) or [Telnyx](https://telnyx.com/products/sip-trunks).

> **Tip**
>
> We will walk through SIP trunking configuration using Twilio in this demo, but the process should be very similar for other SIP trunking providers.

# Outbound

To perform outbound calls, we can simply call the `/conversations/sip/outbound_call` endpoint with a properly configured phone number. Let's walk through the configuration steps below.

First, let's create a SIP trunk and connect it to our phone number. Before starting, make sure you have purchased a phone number on Twilio ([see guide here](https://help.twilio.com/articles/223135247-How-to-Search-for-and-Buy-a-Twilio-Phone-Number-from-Console)).

1. Navigate to the [Trunks](https://www.twilio.com/user/account/sip-trunking/trunks) page and click "Create a New Trunk"
2. Give it a friendly name. This name is for your identification purposes only.
3. Click on the "Termination" page in the side bar.

   ![outbound step 3](/_fern-files/_img/75147c50b818f885d756ef5d2603f553703762540df4996caa81f15a0d48bf52.webp)
4. Configure the Termination SIP URI for this trunk. Record this URI somewhere, as it will be needed for initiating outbound calls.

   ![outbound step 4](/_fern-files/_img/f68ea70a6fdd5b5661a30622a89d366db9e18bd840e1b80a69b11fde18777b3e.webp)
5. Create a new credentials list and add it to the SIP trunk. Record the username and password that you chose, as these will also be needed for initiating outbound calls. This step is technically optional, but it is important for preventing your SIP trunk from being spoofed.

   ![outbound step 5](/_fern-files/_img/11f4e1766dbe2d90a46f81ad7aa615d4d39bede7a613dfa2f932fab27a450327.webp)
6. Click on the "Numbers" page in the side bar and add your number to the SIP trunk.

For more information on termination settings, refer to Twilio docs [here](https://www.twilio.com/docs/sip-trunking#termination).

Once you have a configured SIP trunk with your phone number, simply use the follow code to initiate the call! Remember to include your Termination URI, Username, and Password in the correct headers for verification. Also, make sure you set your config appropriately!

```bash
curl --location 'https://api.phonic.ai/v1/conversations/sip/outbound_call' \
--header 'X-Sip-Address: <your-termination-uri>' \
--header 'X-Sip-Auth-Username: <your-sip-trunk-username>' \
--header 'X-Sip-Auth-Password: <your-sip-password' \
--header 'Content-Type: application/json' \
--header 'Authorization: <your-phonic-api-key>' \
--data '{
    "to_phone_number": "+12345678900",
    "from_phone_number": "+11123581321",
    "config": {
        "welcome_message": "Hello, how can I help you?",
        "system_prompt": "You are a conversational AI assistant talking with a customer over the phone. Always respond to the customer in 1-2 sentences. Naturally end the conversation when the user says goodbye.",
        "voice_id": "grant",
        ...
    }
}'
```

# Inbound

To setup an agent to accept inbound calls, we can simply add one or more properly configured phone numbers to our agent. Let's walk through the configuration steps below.

First, let's create a SIP trunk and connect it to our phone number. Before starting, make sure you have purchased a phone number on Twilio ([see guide here](https://help.twilio.com/articles/223135247-How-to-Search-for-and-Buy-a-Twilio-Phone-Number-from-Console)).

1. Navigate to the [Trunks](https://www.twilio.com/user/account/sip-trunking/trunks) page and click "Create a New Trunk"
2. Give it a friendly name. This name is for your identification purposes only.
3. Click on the "Origination" page in the side bar.
4. Set the Origination URI of this SIP Trunk to `sip:2j1rahun317.sip.livekit.cloud`
5. Click on the "Numbers" page in the side bar and add your number to the SIP trunk.

For more information on origination settings, refer to Twilio docs [here](https://www.twilio.com/docs/sip-trunking#origination).

Once you have a configured SIP trunk with your phone numbers, use the Phonic API to create or update an agent with `{ phone_number: "custom", custom_phone_numbers: [<your_phone_numbers>] }`.

The agent will now be able to receive phone calls on any of the configured phone numbers.

You can use the `configuration_endpoint` agent parameter to customize the agent's behavior based on the incoming phone number.

# SIP Trunk Settings

If your provider requires a specific signaling transport or encrypted media, pass the optional `sip` object when adding a custom phone number. The settings apply to both inbound and outbound calls on that number. To change them later, remove the number and add it again.

```bash
curl --location 'https://api.phonic.ai/v1/agents/<your-agent>/custom-phone-numbers' \
--header 'X-Sip-Address: <your-termination-uri>' \
--header 'X-Sip-Auth-Username: <your-sip-trunk-username>' \
--header 'X-Sip-Auth-Password: <your-sip-password>' \
--header 'Content-Type: application/json' \
--header 'Authorization: <your-phonic-api-key>' \
--data '{
    "phone_number": "+11123581321",
    "sip": {
        "transport": "tls",
        "media_encryption": "required"
    }
}'
```

* `transport`: `auto` (default), `udp`, `tcp` or `tls`. This is the SIP signaling transport. `X-Sip-Address` must be a bare host or IP with an optional port (e.g. `sip.example.com:5061`) — a `;transport=tls` parameter on the address is rejected, so set the transport here instead.
* `media_encryption`: `disabled` (default), `allowed` or `required`. This covers media (SRTP) only and is independent of `transport`. With `required`, calls that can't negotiate SRTP fail rather than falling back to unencrypted media.

The same `sip` object can be passed per call to `/conversations/sip/outbound_call`.

# Phone Call Transfers

If you intend to use the "transfer to phone number", make sure to enable SIP REFER headers and PSTN transfers on your SIP Trunk. See this [link](https://www.twilio.com/docs/sip-trunking/call-transfer) for configuration on Twilio.