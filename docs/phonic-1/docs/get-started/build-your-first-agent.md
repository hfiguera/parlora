> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

Phonic already knows how to listen to callers, speak in turn, and express emotion the way a human would.
What's left to you:

1. **Instructions**: the call flow and rules that shape behavior.
2. **Tools**: how the agent interacts with your systems, and when.
3. **Configuration**: the voice, languages, timing, and switches for your calls.
4. **Deployment**: where your customers can reach your agent.
5. **Evals**: how you improve and tune your agent over time.

This tutorial guides you through building a hypothetical agent that handles reservations for the Phantastic Phood restaurant.

## Step 1: Write the instructions

The system prompt is where you define who the agent is, what a successful call looks like, and guidelines for every call.

```text
You are Sabrina, the host at Phantastic Phood, a restaurant. You are warm
and efficient - callers are often calling from work or on the go.

Your job on every call:
1. Greet the caller and ask what they need.
2. For reservations: get the date, time, and party size, offer at most
   two options from availability, and book once they choose.
3. Confirm the date, time, and party size back to the caller.
4. Once they confirm and have no other questions, say goodbye and end
   the call.

Rules that always apply:
- Never guarantee that a dish is allergen-free — offer to have the
  kitchen give them a call back instead.
- For parties larger than 8, transfer to the events line — do not book
  directly.
- Don't invent menu items or specials; if you don't know, offer to 
  check with the kitchen and then take a callback number to follow up.

If the caller goes quiet and doesn't respond to a check-in, let them
know you'll release the table request for now — they're welcome to
call back to finish the booking — then end the call politely.
```

What to notice:

* **Cover business context beyond the agent configuration.** Check-in timing and wording can be configured ([Step 3](#step-3-configure-the-agent)), but the prompt guides the agent on what to do with the reservation request when the caller stops responding.
* **Nothing here about brevity, contractions, or number formats.** These features are already built into Phonic. See [voice style](/docs/build/agents/prompting_guide#voice-style-prompting).

Now, so that the agent can actually interact with the world around it, like the reservation system or transferring a caller to the events line, we need to configure tools.

## Step 2: Define the tools

Each tool's description is the agent's manual for that tool: what it does and when to call it. The agent sees every attached tool's description on every turn. This page builds three tools; the [tools overview](/docs/build/tools/tools_overview) covers every tool type and its configuration in full.

### The lookup: `check_availability`

```typescript
await client.tools.create({
  name: "check_availability",
  description:
    "Check open reservation slots. Call this when you know the " +
    "date, time, and party size the caller wants. Never offer or " +
    "invent times without calling it first.",
  type: "custom_webhook",
  execution_mode: "sync",
  require_speech_before_tool_call: true, // "Let me check that for you — one sec."
  endpoint_method: "POST",
  endpoint_url: "https://api.phantasticphood.com/availability",
  parameters: [
    {
      type: "string",
      name: "date",
      description: "Requested date, YYYY-MM-DD.",
      is_required: true,
      location: "request_body",
    },
    {
      type: "string",
      name: "time",
      description: "Requested time, 24h HH:MM local.",
      is_required: true,
      location: "request_body",
    },
    {
      type: "integer",
      name: "party_size",
      description: "Number of guests.",
      is_required: true,
      location: "request_body",
    },
  ],
});
```

```python
client.tools.create(
    name="check_availability",
    description=(
        "Check open reservation slots. Call this when you know the "
        "date, time, and party size the caller wants. Never offer or "
        "invent times without calling it first."
    ),
    type="custom_webhook",
    execution_mode="sync",
    require_speech_before_tool_call=True,  # "Let me check that for you — one sec."
    endpoint_method="POST",
    endpoint_url="https://api.phantasticphood.com/availability",
    parameters=[
        {
            "type": "string",
            "name": "date",
            "description": "Requested date, YYYY-MM-DD.",
            "is_required": True,
            "location": "request_body",
        },
        {
            "type": "string",
            "name": "time",
            "description": "Requested time, 24h HH:MM local.",
            "is_required": True,
            "location": "request_body",
        },
        {
            "type": "integer",
            "name": "party_size",
            "description": "Number of guests.",
            "is_required": True,
            "location": "request_body",
        },
    ],
)
```

* **Descriptions guide when tools are called** ("call this when you know\...").
* **Parameter descriptions tell the agent what data to collect** and how to format it ("Requested date, YYYY-MM-DD").
* **In sync mode the agent waits for the result** before it responds. Use it for a lookup whose answer the next sentence depends on.

### The action: `book_table`

```typescript
await client.tools.create({
  name: "book_table",
  description:
    "Book a table for a slot returned by check_availability. Only call " +
    "this after the caller has chosen a specific slot and confirmed the " +
    "spelling of their name.",
  type: "custom_webhook",
  execution_mode: "sync",
  endpoint_method: "POST",
  endpoint_url: "https://api.phantasticphood.com/book",
  parameters: [
    {
      type: "string",
      name: "slot_id",
      description: "The slot_id returned by check_availability.",
      is_required: true,
      location: "request_body",
    },
    {
      type: "string",
      name: "guest_name",
      description: "Caller's full name, spelling confirmed.",
      is_required: true,
      location: "request_body",
    },
    {
      type: "string",
      name: "callback_number",
      description: "Caller's phone number for confirmations.",
      is_required: true,
      location: "request_body",
    },
  ],
});
```

```python
client.tools.create(
    name="book_table",
    description=(
        "Book a table for a slot returned by check_availability. Only call "
        "this after the caller has chosen a specific slot and confirmed the "
        "spelling of their name."
    ),
    type="custom_webhook",
    execution_mode="sync",
    endpoint_method="POST",
    endpoint_url="https://api.phantasticphood.com/book",
    parameters=[
        {
            "type": "string",
            "name": "slot_id",
            "description": "The slot_id returned by check_availability.",
            "is_required": True,
            "location": "request_body",
        },
        {
            "type": "string",
            "name": "guest_name",
            "description": "Caller's full name, spelling confirmed.",
            "is_required": True,
            "location": "request_body",
        },
        {
            "type": "string",
            "name": "callback_number",
            "description": "Caller's phone number for confirmations.",
            "is_required": True,
            "location": "request_body",
        },
    ],
)
```

* **Preconditions about a tool belong on the tool.** The booking tool's description says "only call after… confirmed the spelling".
* **Tool results should return every identifier a later step needs.** Availability returns a slot ID because booking requires one. If a tool doesn't return an identifier, the agent cannot supply it later, which can result in stalling or hallucinations.

### The transfer: `transfer_to_events_line`

```typescript
await client.tools.create({
  name: "transfer_to_events_line",
  description:
    "Transfer the caller to the events team, which handles " +
    "large-party bookings.",
  type: "built_in_transfer_to_phone_number",
  phone_number: "+14155550164",
  require_speech_before_tool_call: true, // "One moment while I connect you."
});
```

```python
client.tools.create(
    name="transfer_to_events_line",
    description=(
        "Transfer the caller to the events team, which handles "
        "large-party bookings."
    ),
    type="built_in_transfer_to_phone_number",
    phone_number="+14155550164",
    require_speech_before_tool_call=True,  # "One moment while I connect you."
)
```

* **Requiring speech before the transfer** has the agent announce the handoff first. This configuration works well for a transfer, where the caller is about to hear a new line, but it may not be suitable for fast tool calls like context lookups. For a handoff built as your own webhook tool, use `wait_for_speech_before_tool_call` (see [tool behavior configuration](/docs/build/tools/tools_overview#tool-behavior-configuration)).
* **A fixed target number is configuration, not prompt content.** The prompt decides *when* to transfer (the "parties larger than 8" rule in [Step 1](#step-1-write-the-instructions)), and the tool guarantees *where*. Leave `phone_number` unset and the agent determines the number at call time instead, which is what you want when the destination depends on the conversation (see [transfer tools](/docs/build/tools/transfer_tools)).

### Remember to update the system prompt!

The tool descriptions cover when and how to call each tool, but the agent needs context on what to do with a result, or what to say when a tool call fails. Add this information to the instructions from Step 1:

```text
Tools:
- If check_availability returns no open tables, offer the waitlist —
  never invent times.
- If a tool fails, apologize, offer to take a callback number, and move
  on. Never go silent while retrying.
```

> **Tip**
>
> For the full anatomy of a good prompt (structure, escalation, voice style), see the [prompting guide](/docs/build/agents/prompting_guide).

## Step 3: Configure the agent

Configurations offer systematic control for the agent.

```typescript
await client.agents.upsert({
  name: "phantastic-phood-host",
  project: "main",
  system_prompt: SYSTEM_PROMPT, // from Steps 1 and 2
  welcome_message:
    "Thanks for calling Phantastic Phood, this is Sabrina — how can I help?",
  voice_id: "sabrina",
  tools: [
    "check_availability",
    "book_table",
    "transfer_to_events_line",
    "choose_not_to_respond",
    "natural_conversation_ending",
  ],
  default_language: "en",
  enable_redaction: true,
  no_input_poke_sec: 30,
  generate_no_input_poke_text: true,
  no_input_end_conversation_sec: 180,
  boosted_keywords: ["Phantastic Phood"],
  pronunciation_dictionary: [{ word: "Phood", pronunciation: "food" }],
  enable_assistant_backchannel: true,
  audio_speed: 1.2,
});
```

```python
client.agents.upsert(
    name="phantastic-phood-host",
    project="main",
    system_prompt=SYSTEM_PROMPT,          # from Steps 1 and 2
    welcome_message=(
        "Thanks for calling Phantastic Phood, this is Sabrina — how can I help?"
    ),
    voice_id="sabrina",
    tools=[
        "check_availability",
        "book_table",
        "transfer_to_events_line",
        "choose_not_to_respond",
        "natural_conversation_ending",
    ],
    default_language="en",
    enable_redaction=True,
    no_input_poke_sec=30,
    generate_no_input_poke_text=True,
    no_input_end_conversation_sec=180,
    boosted_keywords=["Phantastic Phood"],
    pronunciation_dictionary=[{"word": "Phood", "pronunciation": "food"}],
    enable_assistant_backchannel=True,
    audio_speed=1.2,
)
```

What to notice:

* **Voice is `voice_id`.** See [voices](/docs/build/agents/voices) for the catalog.
* **Languages are configuration, never prompt content.** A prompt rule like "speak Portuguese" on an agent configured for English and Spanish produces a confused agent. See [multilingual agents](/docs/build/agents/multilingual).
* **User-side silence handling has two timers**: how long before the agent checks in, and how long before it gives up and ends the call. The check-in wording can be customized, or you can turn on `generate_welcome_message` and `generate_no_input_poke_text` to let the agent generate the most natural message based on the prompt and conversation context.
* **Help it hear and say your terms.** Boosted keywords tell the transcriber which domain words to expect; the [pronunciation dictionary](/docs/build/agents/pronunciation-dictionary) keeps the voice from saying "fud".
* **Redaction** scrubs sensitive details from transcripts (tags like `[NAME]`, `[PHONE]`, `[CREDIT CARD]`) and bleeps them from recordings after the call, for example when the agent takes a credit-card hold for a reservation.
* **Enabling backchanneling** lets the agent murmur "mm-hmm" while the caller is talking, which sounds more natural.
* **Tune the speaking pace** so the booking host speaks a little faster and keeps the call moving.
* **Allow the agent to [end the call naturally](/docs/build/tools/built_in_tools#natural-conversation-ending)**: many AI assistants keep speaking until the user ends the conversation. Phonic agents can hang up once the call has wrapped up.
* **The agent can [choose not to respond](/docs/build/tools/built_in_tools#choose-not-to-respond)** in some cases, such as when the caller is thinking out loud or appears to be talking to someone else.

## Step 4: Deploy your agent

Pick how customers can reach your agent:

* **Inbound phone**: attach a phone number to the agent, either Phonic-provisioned or your own via [Twilio/SIP](/docs/phone-numbers/using_custom_phone_numbers).
* **Outbound phone**: place calls from your backend with the [outbound call API](/api-reference/conversations/outbound-call), passing per-call context as template variables.
* **Your web or mobile app**: connect the same agent over the [WebSocket surface](/docs/build/with-web-sockets/via-web-sockets) for real-time speech-to-speech, with no phone number involved.

The same agent can serve all three at once.

## Step 5: Evaluate its behavior

Write one eval criterion per behavior you care about. A rule that forbids one thing and requires another gets two criteria. A failing criterion then points at the exact line to fix:

> "If the caller asked about allergens or dietary restrictions, the assistant offered a callback from the kitchen."

> "When no tables were available, the assistant offered the waitlist and did not invent times."

The [evals guide](/docs/build/agents/evals_guide) covers extraction schemas, eval prompts, and the improvement loop.

## Where each kind of rule goes

| You want to control...                            | Put it in                                                                                    | Example                                                                                                                                             |
| ------------------------------------------------- | -------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| When and how one tool is used                     | The **tool's description**                                                                   | "Call as soon as you know date, time, and party size"                                                                                               |
| What data a tool needs, and its format            | The tool's **parameter descriptions**                                                        | "Requested date, YYYY-MM-DD"                                                                                                                        |
| Whether the agent speaks before/after a tool call | **Tool behavior configuration**                                                              | `wait_for_speech_before_tool_call`                                                                                                                  |
| Business policy that holds on every call          | The **instructions** (Rules that always apply)                                               | "Never guarantee a dish is allergen-free"                                                                                                           |
| The order of steps across tools                   | The **instructions** (call flow)                                                             | "Offer at most two options, then book"                                                                                                              |
| Behavior on tool results and failures             | The **instructions** (Tools section)                                                         | "If no tables, offer the waitlist"                                                                                                                  |
| The first thing the caller hears                  | **Agent configuration**                                                                      | `welcome_message`, or `generate_welcome_message` to have the agent compose it                                                                       |
| A fixed line after caller silence, every time     | **Agent configuration**                                                                      | `no_input_poke_text`, translated to the call language as needed                                                                                     |
| A check-in that fits where the call is            | **Agent configuration** (`generate_no_input_poke_text`), composed from the **system prompt** | "Still there? I can hold that 6:45 for a moment"                                                                                                    |
| When silence triggers a check-in or hangup        | **Agent configuration**                                                                      | `no_input_poke_sec`                                                                                                                                 |
| Which languages the agent speaks                  | **Agent configuration**                                                                      | `default_language`, additional languages                                                                                                            |
| Speech style, spoken formats, disfluencies        | **Nowhere, built in**                                                                        | see [voice style](/docs/build/agents/prompting_guide#voice-style-prompting)                                                                         |
| Transfer targets and voicemail detection          | **Transfer tool configuration**                                                              | [transfer tools](/docs/build/tools/transfer_tools)                                                                                                  |
| Per-caller context (name, account, reason)        | **Template variables**                                                                       | [template variables](/docs/build/agents/template-variables), [agent configuration endpoint](/docs/build/with-webhooks/agent-configuration-endpoint) |