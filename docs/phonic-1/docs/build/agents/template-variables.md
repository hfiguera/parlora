> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Template Variables

> Fill per-conversation details into your agent's prompt and greeting, and use built-in system variables such as the date, the caller's number, and a recap of the caller's past conversations.

Template variables let one agent serve every conversation with the right details filled in. Write a placeholder like `{{customer_name}}` in the system prompt or welcome message, and Phonic replaces it with a value when the conversation starts.

There are two kinds:

* **System variables** start with `system_` and are filled in by Phonic automatically: the current date and time, the phone numbers on the call, the conversation ID, and a recap of the caller's past conversations.
* **Custom variables** are any other names you choose. You give them values per conversation, with optional defaults on the agent.

**`System prompt`**

```text title="System prompt"
You are the receptionist for Bright Smile Dental. You are speaking with {{customer_name}}.
Today is {{system_weekday}}, {{system_date}} {{system_year}}. The current time is {{system_time}}.

Summaries of this caller's previous calls, newest first:
{{system_past_conversations_summary}}
```

## Syntax

Wrap the variable name in double curly braces with no spaces: `{{customer_name}}`.

Names are snake_case: they start with a lowercase letter and contain only lowercase letters, digits, and single underscores between words, such as `customer_name` or `plan_tier_2`.

Anything that doesn't match this pattern isn't treated as a variable and is left in the text exactly as written. For example, `{{ customer_name }}` (with spaces), `{{CustomerName}}`, and `{customer_name}` all stay as literal text. There is no escape syntax.

## Remembering past callers

`{{system_past_conversations_summary}}` gives your agent a short memory of the caller. When a phone call starts, Phonic fills in a recap of the caller's 5 most recent conversations, so the agent can pick up where the last call left off ("Hi again, are you calling about Friday's appointment?") instead of starting from scratch.

There is nothing to enable. Phonic writes a 1–2 sentence summary of every conversation after it ends, and the variable is available to every agent. The recap only ever includes the 5 most recent summaries, however far back they go, so it stays short no matter how many times someone has called. The limit of 5 is fixed and can't be configured.

### What it contains

One line per past conversation, newest first. Each line starts with how long ago the conversation began, followed by its summary:

```text
[2 days ago] The caller booked a cleaning for Friday at 3 PM and asked for a text reminder the day before.
[1 month ago] The caller asked whether Delta Dental insurance is accepted and was told it is.
```

### Which conversations are included

* **Same phone number.** For inbound calls, Phonic matches the caller's number, which is the caller ID that arrives with the call. Phonic doesn't read call-forwarding headers, so if you forward calls to a Phonic number, the match uses whatever number your carrier presents as the caller. For outbound calls, it matches the number being called. A past conversation matches if that number was on either side of the call, so inbound and outbound calls with the same person are both included.
* **Same project.** Conversations from every agent in the project are included, not just the current agent.
* **The 5 most recent** matching conversations that have a summary. There is no time limit on how far back they go.
* Conversations with an empty transcript have no summary and are skipped. So are conversations whose transcripts have been deleted, for example under a [data retention policy](/docs/platform/retention).

### When it is empty

The variable is filled with an empty string, and the rest of the prompt is unaffected, when:

* The conversation isn't a phone call, such as a conversation started over a [WebSocket](/docs/build/with-web-sockets/via-web-sockets) from a browser or app.
* The caller has no earlier conversations with a summary in the project, for example on their first call.
* The caller's number is withheld (anonymous caller ID).

Write the prompt so it reads well either way, for example:

**`System prompt`**

```text title="System prompt"
## Caller history
Summaries of this caller's previous calls, newest first. If this section is empty, this is their first call.
{{system_past_conversations_summary}}

Use this history to avoid asking for details the caller has already given. Don't read the summaries out loud.
```

> **Note**
>
> Summaries are written shortly after each conversation ends. If someone calls back immediately, their most recent call may not be summarized yet.

## System variables

System variables are always available and don't need to be declared on the agent.

| Variable                                | Value                                                                                                                                                                       | Example                                                    |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| `{{system_past_conversations_summary}}` | Recap of the caller's 5 most recent past conversations. See [Remembering past callers](#remembering-past-callers).                                                          | `[2 days ago] The caller booked a cleaning…`               |
| `{{system_date}}`                       | Today's month and day                                                                                                                                                       | `October 14th`                                             |
| `{{system_year}}`                       | Current year                                                                                                                                                                | `2026`                                                     |
| `{{system_month}}`                      | Current month name                                                                                                                                                          | `October`                                                  |
| `{{system_day}}`                        | Day of the month                                                                                                                                                            | `14`                                                       |
| `{{system_weekday}}`                    | Day of the week                                                                                                                                                             | `Wednesday`                                                |
| `{{system_time}}`                       | Current time                                                                                                                                                                | `3:05 PM`                                                  |
| `{{system_next_2_weeks}}`               | 14 lines, one per day starting today, with today marked                                                                                                                     | `2026-10-14 (Wednesday) – Today` `2026-10-15 (Thursday)` … |
| `{{system_conversation_timezone}}`      | Time zone used for all the date and time variables                                                                                                                          | `America/Los_Angeles`                                      |
| `{{system_from_phone_number}}`          | Phone number the call is from. For inbound calls this is the caller; for outbound calls, the number Phonic dials from. `Unknown` when the conversation isn't a phone call.  | `+15551234567`                                             |
| `{{system_to_phone_number}}`            | Phone number the call is to. For inbound calls this is the agent's number; for outbound calls, the number being called. `Unknown` when the conversation isn't a phone call. | `+15557654321`                                             |
| `{{system_conversation_id}}`            | ID of the current conversation                                                                                                                                              | `conv_12cf6e88-c254-…`                                     |
| `{{system_project_name}}`               | Name of the project                                                                                                                                                         | `main`                                                     |
| `{{system_workspace}}`                  | Name of the workspace                                                                                                                                                       | `bright-smile`                                             |

The date and time are taken when the conversation starts and don't change during it.

### Time zone

The date and time variables use the agent's `timezone` setting, or `America/Los_Angeles` if none is set. To use a different time zone for one conversation, pass `system_conversation_timezone` in that conversation's `template_variables`, for example `"system_conversation_timezone": "America/New_York"`. It must be a valid IANA time zone name.

New agents start with a system prompt that already uses the date and time variables:

```text
Today's date is {{system_date}} {{system_year}}. The day of week is {{system_weekday}}. The current time is {{system_time}}. The timezone for the current conversation is {{system_conversation_timezone}}. Use it only for date/time calculations. Do not infer location from it.
```

### Overriding a system variable

A value you pass for a system variable in a conversation's `template_variables` replaces the built-in value for that conversation. Names that start with `system_` but aren't in the table above are rejected.

## Custom variables

### Declare them on the agent

Use a variable in the agent's system prompt or welcome message, and it becomes one of the agent's template variables. For each one you can set:

* **A default value**, used when a conversation doesn't provide one. The default can be an empty string.
* **Boosting** (`is_boosted_keyword`), which adds the variable's value to the agent's [boosted keywords](/api-reference/agents/create) so the agent recognizes it more accurately when the caller says it, which helps with names. Values of boosted variables can be at most 50 characters.

A variable with no default is **required**: every conversation must provide a value for it, or the conversation doesn't start.

In the dashboard, open your agent. Variables you type into the system prompt or welcome message appear under **Template variables**, each with a **Default value** field and a **Boost** checkbox. The info icon next to the heading lists the system variables with live example values.

With the API, set `template_variables` when you [create](/api-reference/agents/create) or [update](/api-reference/agents/update) an agent:

```typescript
await client.agents.create({
  name: "dental-receptionist",
  welcome_message: "Hi {{customer_name}}, thanks for calling Bright Smile Dental!",
  system_prompt:
    "You help {{customer_name}} manage their {{appointment_type}} appointment.\n\nPrevious calls:\n{{system_past_conversations_summary}}",
  template_variables: {
    customer_name: { default_value: "there", is_boosted_keyword: true },
    // appointment_type has no default, so every conversation must provide it.
  },
});
```

```python
client.agents.create(
    name="dental-receptionist",
    welcome_message="Hi {{customer_name}}, thanks for calling Bright Smile Dental!",
    system_prompt=(
        "You help {{customer_name}} manage their {{appointment_type}} appointment.\n\n"
        "Previous calls:\n{{system_past_conversations_summary}}"
    ),
    template_variables={
        "customer_name": {"default_value": "there", "is_boosted_keyword": True},
        # appointment_type has no default, so every conversation must provide it.
    },
)
```

The agent keeps only the variables its system prompt, welcome message, and listen-only inbound message actually use. Entries in `template_variables` for names that don't appear in any of them are dropped.

### Pass values for a conversation

Pass values as `template_variables`, an object of string values, wherever the conversation is started:

* **Outbound calls**: in `config` on the [outbound call](/api-reference/conversations/outbound-call) and SIP outbound call endpoints.
* **WebSocket conversations**: in the [`config` message](/docs/build/with-web-sockets/via-web-sockets).
* **Inbound calls**: in the response from your [agent configuration endpoint](/docs/build/with-webhooks/agent-configuration-endpoint), which can look the caller up before the call starts.

```typescript
await client.conversations.outboundCall({
  to_phone_number: "+15551234567",
  config: {
    agent: "dental-receptionist",
    template_variables: {
      customer_name: "Dana",
      appointment_type: "cleaning",
    },
  },
});
```

```python
client.conversations.outbound_call(
    to_phone_number="+15551234567",
    config={
        "agent": "dental-receptionist",
        "template_variables": {
            "customer_name": "Dana",
            "appointment_type": "cleaning",
        },
    },
)
```

```bash
curl https://api.phonic.ai/v1/conversations/outbound_call \
  -H "Authorization: Bearer $PHONIC_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "to_phone_number": "+15551234567",
    "config": {
      "agent": "dental-receptionist",
      "template_variables": {
        "customer_name": "Dana",
        "appointment_type": "cleaning"
      }
    }
  }'
```

Values you pass are combined with the agent's defaults: a value you pass wins, and any variable you leave out uses its default. If a required variable has no value, the conversation doesn't start, and the error names the missing variables.

If the start request includes `template_variables`, those values are used and any `template_variables` returned by the configuration endpoint are ignored. The two sets aren't merged.

You can also start a conversation without an agent by passing `system_prompt` and `welcome_message` directly. Every custom variable they use must then have a value in `template_variables`.

The values used for each conversation are recorded in its `template_variables` field, which you can see on the [conversation](/api-reference/conversations/get) and in the [`conversation.ended`](/docs/build/with-webhooks/post-call-webhooks/conversation-ended) webhook.

## The `metadata` variable

`metadata` is a reserved name. If your [agent configuration endpoint](/docs/build/with-webhooks/agent-configuration-endpoint) returns a `metadata` object, `{{metadata}}` in the system prompt is replaced with that object as a JSON string. This is a convenient way to hand the agent a structured record, such as a CRM lookup, without declaring a variable for each field.

* `{{metadata}}` works only in the system prompt. A welcome message that uses it is rejected.
* If the system prompt uses `{{metadata}}` and the configuration endpoint returns no `metadata`, the conversation doesn't start.
* You can't declare a custom variable named `metadata`.

## Where variables are filled in

| Where                                                                              | Variables available                                                                                     |
| ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| System prompt                                                                      | System, custom, and `{{metadata}}`                                                                      |
| Welcome message                                                                    | System and custom. Not used when `generate_welcome_message` is `true`, since the greeting is generated. |
| Listen-only inbound message (`listen_only_inbound_message`)                        | System and custom                                                                                       |
| [Webhook tool](/docs/build/tools/webhook_tools) header values (`endpoint_headers`) | Custom only                                                                                             |

Variables are filled in once, when the conversation starts. They aren't filled in anywhere else, including:

* Tool names, descriptions, and parameters.
* Webhook tool URLs and request bodies.
* Other tool types, including WebSocket tools, context tools, and MCP tools.
* Messages sent during a conversation, such as `add_system_message`. An `update_system_prompt` message that contains custom variables is rejected.

### Webhook tool headers

Header values on a [Webhook tool](/docs/build/tools/webhook_tools) can contain custom variables. This lets you send a per-conversation credential or identifier to your endpoint:

```json
{
  "endpoint_headers": {
    "Authorization": "Bearer {{customer_api_token}}",
    "X-Customer-Id": "{{customer_id}}"
  }
}
```

Only variables that have a value in the conversation (passed values and agent defaults) are filled in. System variables aren't available here, and a variable with no value is sent as the literal text, such as `{{customer_id}}`. The conversation ID and phone numbers are already sent to your endpoint as [call context](/docs/build/tools/webhook_tools#call-context-information).

The agent only stores defaults for variables used in its prompts, so pass header-only variables in each conversation's `template_variables`.

## Common mistakes

| Mistake                                                                                                                               | Wrong                                                                   | Right                                                                                                    |
| ------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Spaces or capitals inside the braces. The text isn't recognized as a variable and is sent to the model as written.                    | `{{ customer_name }}`, `{{CustomerName}}`                               | `{{customer_name}}`                                                                                      |
| Misspelling a system variable. Names starting with `system_` aren't checked when you save the agent.                                  | `{{system_past_conversation_summary}}`, `{{system_today}}`              | Copy the name from the [table](#system-variables)                                                        |
| Leaving a variable without a default and not passing it. The conversation doesn't start.                                              | `{{account_id}}` in the prompt, no default, not in `template_variables` | Pass a value every time, or set a default (it can be empty)                                              |
| Expecting caller history in a browser or app conversation. The summary is matched by phone number, so it's empty outside phone calls. | `{{system_past_conversations_summary}}` in a WebSocket-only agent       | Pass your own history in a custom variable or `{{metadata}}`                                             |
| Writing a prompt that only makes sense when the summary has content.                                                                  | "Greet the caller by referencing their last call."                      | "If there are previous calls listed, briefly acknowledge the most recent one."                           |
| Using system variables in webhook tool headers. They aren't filled in there.                                                          | `X-Conversation: {{system_conversation_id}}`                            | Read `conversation_id` from the [call context](/docs/build/tools/webhook_tools#call-context-information) |
| Putting template variables in a tool description or URL. They're only filled in where listed [above](#where-variables-are-filled-in). | `GET https://api.example.com/{{customer_id}}/orders`                    | Pass the value as a tool parameter, or as a webhook header                                               |