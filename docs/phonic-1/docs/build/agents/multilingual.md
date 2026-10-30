> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Multilingual Agents

> Configure which languages your agent speaks and how it switches between them.

Language settings should be set using the following three fields, when you configure an [agent](/api-reference/agents/create) or [start an agentless conversation](/docs/build/with-webhooks/agent-configuration-endpoint):

| Field                  | What it does                                                            | Default   |
| ---------------------- | ----------------------------------------------------------------------- | --------- |
| `default_language`     | The language the agent recognizes and speaks from the start of the call | `en`      |
| `additional_languages` | Other languages the agent can recognize and speak                       | `[]`      |
| `multilingual_mode`    | How the agent decides to switch between them                            | `request` |

See [Supported Languages](/docs/build/agents/supported_languages) for the language codes to use.

## Choosing a switching mode

| Mode                    | The agent switches…                     | Choose it when                                                |
| ----------------------- | --------------------------------------- | ------------------------------------------------------------- |
| `request` (recommended) | only when the caller explicitly asks    | calls stay in one language, or change occasionally on request |
| `auto`                  | to the language of each caller turn     | callers code-switch often, sometimes every turn               |
| `initial`               | on the first turn, then only on request | you don't know the caller's language until they speak         |

### `request`: switch on explicit ask

The conversation stays in the current language until the caller asks to change it:

> Caller: "Can we speak in French?"
>
> Agent *(switching)*: "Bien sûr — qu'est-ce que je peux faire pour vous ?"

A stray word or sentence in another language does **not** trigger a switch. The caller must actually request it, **in the language the conversation is currently in**. From an English conversation, "can you speak French" works. Once the conversation is in French, "can you speak English" will not work, the caller needs "tu peux parler anglais".

This keeps calls language-stable and transcription steady, which is why it's the default and the recommended mode.

### `auto`: mirror the caller turn by turn

Each caller turn is identified for its language, and the agent responds in kind:

> Caller: "Hey, can you help me move my appointment?"
>
> Agent: "Sure — what time works better?"
>
> Caller: "Au fait, est-ce que tu parles français ?"
>
> Agent: "Oui, bien sûr !"

`auto` fits callers who move between languages: bilingual households, mixed-language teams. Two constraints: it supports at most **2 additional languages**, and because every turn is language-identified, declaring only the languages you actually expect matters most in this mode.

### `initial`: first turn decides

The caller's first turn sets the language, and from there the conversation behaves like `request`: it stays in that language until the caller explicitly asks to change. A caller who opens in Spanish gets a Spanish conversation, even if a later turn contains English words. A good fit when you don't know which language a caller will use, such as outbound lists that span languages.

## Welcome and check-in messages

Static welcome and check-in messages should be written in the default language. A `welcome_message` of "bonjour" on an agent whose `default_language` is `en` will sound like French spoken in an English-speaking voice. Static `no_input_poke_text` is translated into the conversation's current language when the call has moved off the default, but the welcome message is spoken before any of that is known. This means that if you want to change the default language of the agent, you will need to also update the static texts.

However, when you set `generate_welcome_message` or `generate_no_input_poke_text`, the agent will speak them in the language the conversation is in at that point in time. The generated welcome and check-in messages are based on the system prompt and conversation history.

## Configuration

```typescript
await client.agents.upsert({
  name: "phantastic-phood-host",
  project: "main",
  default_language: "en",
  additional_languages: ["es"],
  multilingual_mode: "request",
  // Static text is spoken as written, so keep it in the default language.
  welcome_message: "Thanks for calling Phantastic Phood — how can I help?",
  // Generated instead of fixed, so the check-in follows the conversation's language.
  generate_no_input_poke_text: true,
});
```

```python
client.agents.upsert(
    name="phantastic-phood-host",
    project="main",
    default_language="en",
    additional_languages=["es"],
    multilingual_mode="request",
    # Static text is spoken as written, so keep it in the default language.
    welcome_message="Thanks for calling Phantastic Phood — how can I help?",
    # Generated instead of fixed, so the check-in follows the conversation's language.
    generate_no_input_poke_text=True,
)
```

## Rules of thumb

* **Never put language policy in the prompt.** "Respond in Portuguese" on an agent configured for English and Spanish produces a confused agent.
* **Declare only the languages you actually expect on calls.** Don't add languages "just in case".
* **Keep static welcome and check-in text in the default language**, or generate it instead. See [Welcome and check-in messages](#welcome-and-check-in-messages).
* **To change an agent's languages per call**, consider setting up webhooks to use the [agent configuration endpoint](/docs/build/with-webhooks/agent-configuration-endpoint) instead of creating one agent per language.