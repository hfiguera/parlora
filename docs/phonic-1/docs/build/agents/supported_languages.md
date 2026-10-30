> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Supported Languages

> The 51 languages Phonic agents can recognize and speak, with the language code to use in the API.

Phonic agents recognize and speak the 51 languages below. Use the code in the **Language ID** column wherever the API takes a language: `default_language` and `additional_languages` when you [configure an agent](/api-reference/agents/create) or [start an agentless conversation](/docs/build/with-webhooks/agent-configuration-endpoint).

Codes are [ISO 639-1](https://en.wikipedia.org/wiki/List_of_ISO_639_language_codes) two-letter codes, except Filipino (`fil`) and Cantonese (`yue`), which have no ISO 639-1 code.

| Language ID | Language           | Also known as                         |
| ----------- | ------------------ | ------------------------------------- |
| `ar`        | Arabic             | Modern Standard Arabic, MSA           |
| `az`        | Azerbaijani        | Azeri                                 |
| `bg`        | Bulgarian          |                                       |
| `bn`        | Bengali            | Bangla                                |
| `cs`        | Czech              |                                       |
| `da`        | Danish             |                                       |
| `de`        | German             | Deutsch                               |
| `el`        | Greek              | Modern Greek                          |
| `en`        | English            |                                       |
| `es`        | Spanish            | Castilian, Español                    |
| `fa`        | Persian            | Farsi                                 |
| `fi`        | Finnish            | Suomi                                 |
| `fil`       | Filipino           | Tagalog                               |
| `fr`        | French             | Français                              |
| `gu`        | Gujarati           |                                       |
| `he`        | Hebrew             | Modern Hebrew, Ivrit                  |
| `hi`        | Hindi              |                                       |
| `hu`        | Hungarian          | Magyar                                |
| `id`        | Indonesian         | Bahasa Indonesia                      |
| `it`        | Italian            | Italiano                              |
| `ja`        | Japanese           | Nihongo                               |
| `ka`        | Georgian           | Kartuli                               |
| `km`        | Khmer              | Cambodian                             |
| `kn`        | Kannada            |                                       |
| `ko`        | Korean             | Hangugeo                              |
| `lt`        | Lithuanian         |                                       |
| `lv`        | Latvian            |                                       |
| `ml`        | Malayalam          |                                       |
| `mr`        | Marathi            |                                       |
| `ms`        | Malay              | Bahasa Melayu                         |
| `ne`        | Nepali             |                                       |
| `nl`        | Dutch              | Nederlands, Flemish                   |
| `no`        | Norwegian          | Norsk, Bokmål                         |
| `pa`        | Punjabi            | Panjabi                               |
| `pl`        | Polish             | Polski                                |
| `pt`        | Portuguese         | Português                             |
| `ro`        | Romanian           | Română                                |
| `ru`        | Russian            |                                       |
| `si`        | Sinhala            | Sinhalese                             |
| `sk`        | Slovak             |                                       |
| `sq`        | Albanian           | Shqip                                 |
| `sv`        | Swedish            | Svenska                               |
| `sw`        | Swahili            | Kiswahili                             |
| `ta`        | Tamil              |                                       |
| `te`        | Telugu             |                                       |
| `th`        | Thai               |                                       |
| `tr`        | Turkish            | Türkçe                                |
| `uk`        | Ukrainian          |                                       |
| `ur`        | Urdu               |                                       |
| `vi`        | Vietnamese         | Tiếng Việt                            |
| `yue`       | Cantonese          | Yue Chinese                           |
| `zh`        | Chinese (Mandarin) | Mandarin, Standard Chinese, Putonghua |

## Using more than one language on a call

An agent has one `default_language` and any number of `additional_languages`, and `multilingual_mode` controls how it moves between them. See [Multilingual Agents](/docs/build/agents/multilingual) for the switching modes and for how welcome and check-in messages behave.

> **Note**
>
> Declare only the languages you actually expect on calls. Adding languages "just in case" makes recognition harder, not more flexible.