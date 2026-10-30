> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Transfer Tools

> Transfer a call to a phone number or hand it off to another Phonic Agent.

Transfer tools hand the live call off to a human, a queue, another system, or another Phonic Agent. Both transfer types cannot have parameters and always run in `sync` mode.

See [Tool Definition](/docs/using-tools/tools_overview#tool-definition) for the shared fields and [Tool Behavior Configuration](/docs/using-tools/tools_overview#tool-behavior-configuration) for the behavior toggles.

# Transfer to Phone Number

The `built_in_transfer_to_phone_number` tool transfers the call to a phone number — a human, a queue, or even another system. In the dashboard choose **Transfer to phone number**.

Key fields:

* **Phone number** (`phone_number`) — the E.164 number to transfer to. Toggle **Agent chooses** to let the agent determine the number at runtime (`phone_number` stored as `null`).
* **DTMF** (`dtmf`) — optional digits to send after the transfer connects. Toggle **Agent chooses** (`dynamic_dtmf`) to let the agent decide. See [DTMF characters](#dtmf-characters) below for what the string accepts, including `w` to insert a pause.
* **Use agent phone number for transfer** (`use_agent_phone_number`) — when enabled, Phonic transfers using the agent's phone number. When disabled, it transfers using the connected party's number (a SIP REFER), and DTMF is not sent.
* **Allow Phonic to detect and handle voicemail** (`detect_voicemail`) — only available when using the agent's phone number.
* **Uninterruptible** (`uninterruptible`) — enabled by default, including for existing phone transfers without this setting. Set to `false` to allow caller speech to interrupt the transfer tool.

Prevents caller interruptions during the transfer, including the preceding announcement once protection is active.

```typescript
import { PhonicClient } from "phonic";

const apiKey = process.env.PHONIC_API_KEY;
const client = new PhonicClient({ apiKey });

async function createTool() {
  await client.tools.create({
    name: "transfer_to_support",
    description: "Transfers the call to the support team",
    type: "built_in_transfer_to_phone_number",
    execution_mode: "sync",
    phone_number: "+15551234567", // E.164 format
  });
}

createTool()
```

```python
import os
from dotenv import load_dotenv
from phonic import Phonic

load_dotenv(".env.local")

client = Phonic(api_key=os.getenv("PHONIC_API_KEY"))

client.tools.create(
    name="transfer_to_support",
    description="Transfers the call to the support team",
    type="built_in_transfer_to_phone_number",
    execution_mode="sync",
    phone_number="+15551234567",
)
```

## DTMF characters

The `dtmf` string accepts digits `0`–`9`, `*`, `#`, the lowercase letters `a`–`d`, and `w` for a pause. Phonic removes any character outside that set before sending.

| Character       | Supported | Effect                                                                                      |
| --------------- | --------- | ------------------------------------------------------------------------------------------- |
| `0`–`9`         | Yes       | Keypad digit tone.                                                                          |
| `*`             | Yes       | Star tone.                                                                                  |
| `#`             | Yes       | Pound (hash) tone.                                                                          |
| `a` `b` `c` `d` | Yes       | A/B/C/D tones, a fourth DTMF column that ordinary phones don't have. Most IVRs ignore them. |
| `w`             | Yes       | A pause of 0.5 seconds. Repeat to lengthen it, so `www` waits 1.5 seconds.                  |
| `A` `B` `C` `D` | No        | Removed before sending. Use lowercase for A/B/C/D tones.                                    |
| `W`             | No        | Removed before sending, and not a pause. Use lowercase `w`.                                 |
| `,`             | No        | Removed before sending, and not a pause despite the convention elsewhere. Use `w`.          |
| Anything else   | No        | Removed before sending.                                                                     |

Each digit takes about half a second to play: a 250 ms tone followed by a 250 ms gap. A `w` pause is 0.5 seconds with no trailing gap. Neither is configurable.

> **Note**
>
> An unsupported character is removed before the string is sent, so it doesn't play and the rest of the sequence is unaffected. Uppercase `A`–`D` and `W` are the common case, since `w` and `a`–`d` are recognized in lowercase only.

There's no maximum length for `dtmf`. Pass `null`, not an empty string, when no digits should be sent.

> **Note**
>
> No digits are sent on a SIP REFER transfer, and the API rejects a non-null `dtmf` for one. See **Use agent phone number for transfer** under [Transfer to Phone Number](#transfer-to-phone-number).

# Transfer to Agent

The `built_in_transfer_to_agent` tool hands the conversation off to another Phonic Agent. In the dashboard choose **Transfer to agent** and select one or more agents in **Agents to transfer to** (`agents_to_transfer_to`). Use the tool's description to tell the agent which target to pick (e.g. route Enterprise vs Starter callers to different agents).

```typescript
await client.tools.create({
  name: "transfer_to_finance",
  description:
    "For finance queries, transfer to 'finance-enterprise-agent' for Enterprise plans, else 'finance-starter-agent'.",
  type: "built_in_transfer_to_agent",
  execution_mode: "sync",
  agents_to_transfer_to: ["finance-enterprise-agent", "finance-starter-agent"],
});
```

```python
client.tools.create(
    name="transfer_to_finance",
    description="For finance queries, transfer to 'finance-enterprise-agent' for Enterprise plans, else 'finance-starter-agent'.",
    type="built_in_transfer_to_agent",
    execution_mode="sync",
    agents_to_transfer_to=["finance-enterprise-agent", "finance-starter-agent"],
)
```