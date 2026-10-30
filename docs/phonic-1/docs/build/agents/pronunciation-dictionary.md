> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Pronunciation Dictionary

> Control how your agent says brand names, product names, and other domain terms.

The pronunciation dictionary tells the agent's voice how to say specific words. Each entry pairs a **word** with a **pronunciation**: whenever the agent is about to say the word, the voice reads the pronunciation instead.

Use it for terms the voice gets wrong on its own, such as brand names ("Phood" read as "fud"), place names ("Phuket"), acronyms you want read a particular way, or product names with unusual spellings.

> **Note**
>
> The dictionary changes only how the agent **speaks**. To help the agent **recognize** a term when the caller says it, add it to `boosted_keywords` instead. Many terms belong in both.

## Writing entries

Write the pronunciation as a respelling in ordinary letters, the way you'd want it read aloud:

| Word     | Pronunciation | The agent says |
| -------- | ------------- | -------------- |
| `Phood`  | `food`        | "food"         |
| `Phuket` | `Poo-ket`     | "Poo-ket"      |
| `SQL`    | `sequel`      | "sequel"       |
| `etc`    | `et cetera`   | "et cetera"    |

The pronunciation is passed to the voice as plain text. There is no phoneme, IPA, or SSML syntax.

## How matching works

When the agent speaks, each entry's word is replaced by its pronunciation before the text reaches the voice:

* **Case-insensitive.** `Phood` also matches `phood` and `PHOOD`.
* **Whole words only.** `Phood` matches "Phood" and "Phood's", but not "Phoods" or "Phoodie". Add a separate entry for each form you need, such as `Phoods` → `foods`.
* **Applies to everything the agent says**, including the welcome message.
* **Transcripts keep the original word.** With Phonic voices, the conversation transcript shows "Phood", not "food".

## Configure it in the dashboard

1. Open your agent and go to the **Advanced** tab.
2. Under **Pronunciation dictionary**, click **Add word**.
3. Enter the word in the first field and its pronunciation in the second.
4. Save the agent.

Use the trash icon next to an entry to remove it.

## Configure it with the API

Set `pronunciation_dictionary` to a list of `{ word, pronunciation }` objects when you [create](/api-reference/agents/create) or [update](/api-reference/agents/update) an agent:

```typescript
await client.agents.update("phantastic-phood-host", {
  project: "main",
  pronunciation_dictionary: [
    { word: "Phood", pronunciation: "food" },
    { word: "Phoods", pronunciation: "foods" },
  ],
});
```

```python
client.agents.update(
    "phantastic-phood-host",
    project="main",
    pronunciation_dictionary=[
        {"word": "Phood", "pronunciation": "food"},
        {"word": "Phoods", "pronunciation": "foods"},
    ],
)
```

Updating `pronunciation_dictionary` replaces the whole list. To add one entry, send the existing entries plus the new one. To clear the dictionary, send `[]`.

You can also set `pronunciation_dictionary` for a single conversation, in the WebSocket [`config` message](/docs/build/with-web-sockets/via-web-sockets) or in the response from your [agent configuration endpoint](/docs/build/with-webhooks/agent-configuration-endpoint). A list provided there replaces the agent's dictionary for that conversation; it isn't merged with it.

## Limits

|                        | Limit         |
| ---------------------- | ------------- |
| Entries per dictionary | 1,000         |
| `word` length          | 30 characters |
| `pronunciation` length | 50 characters |

Both fields are required and are trimmed of leading and trailing spaces. Each word can appear only once, compared case-insensitively, so `Phood` and `phood` can't both be entries.

## Common mistakes

The pronunciation is dropped into the agent's speech exactly as written, so anything in it gets said out loud.

| Mistake                                                                                                         | Wrong                                                                                    | Right                                                                              |
| --------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Putting instructions or descriptions in the pronunciation. The whole string is spoken.                          | `Poo-ket with a short e`, `rhymes with cat`, `stress on 2nd syllable`, `nite (silent k)` | `Poo-ket`, `nite`                                                                  |
| Using IPA, SSML, or phoneme tags. They aren't interpreted and can be read out or garbled.                       | `/ˈpuːkɛt/`, `<phoneme ph="puːkɛt">`, `[poo-KET]`                                        | `Poo-ket`                                                                          |
| Using notation the voice can pause on or voice, such as slashes, parentheses, or all-caps syllables for stress. | `Poo / ket`, `Poo (ket)`, `poo-KET`                                                      | `Poo-ket`                                                                          |
| Expecting the dictionary to fix recognition. It only changes speech, and transcripts keep the original word.    | A pronunciation entry for a term callers say that the agent mishears                     | Add the term to `boosted_keywords`                                                 |
| Expecting partial-word matches. Only whole words match.                                                         | `Phonic` → `Fonic`, expecting "Phonics" to change too                                    | Add `Phonics` → `Fonics` as its own entry                                          |
| Adding the same word in different cases. Duplicates are rejected, and one entry already covers every casing.    | `Phood` and `PHOOD` as two entries                                                       | One `Phood` entry                                                                  |
| Sending only the new entry in an API update. The list you send replaces the whole dictionary.                   | `pronunciation_dictionary: [{ word: "Phoods", ... }]`                                    | Send every existing entry plus the new one                                         |
| Using a word that starts or ends with a symbol. Matching uses word boundaries, so it may not match.             | `C++`, `.NET`                                                                            | Entries that start and end with a letter or digit                                  |
| Adding entries for things Phonic already reads naturally.                                                       | Entries for numbers, emails, phone numbers, or alphanumeric IDs                          | Add entries only for terms the voice gets wrong                                    |
| Writing phonetics into the prompt instead.                                                                      | "Say Phood as food" in the system prompt                                                 | A dictionary entry. See the [prompting guide](/docs/build/agents/prompting_guide). |