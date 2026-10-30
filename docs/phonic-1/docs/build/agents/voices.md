> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Voices

> The voices available for Phonic agents, with the voice ID to use in the API.

Set `voice_id` when you [configure an agent](/api-reference/agents/create), [start an agentless conversation](/docs/build/with-webhooks/agent-configuration-endpoint), or use the [LiveKit plugin](/docs/build/with-livekit). Use the value in the **Voice ID** column.

You can also list the voices available to your workspace with [`voices.list`](/api-reference/voices/list).

| Voice ID    | Name      | Gender | Accent                              | Style                              |
| ----------- | --------- | ------ | ----------------------------------- | ---------------------------------- |
| `sabrina`   | Sabrina   | Female |                                     | Cheerful, Expressive, Polished     |
| `grant`     | Grant     | Male   |                                     | Chill, Casual, Friendly            |
| `sandeep`   | Sandeep   | Male   | Strong Indian Accent                | Subdued, Monotone, Serious         |
| `landon`    | Landon    | Male   |                                     | Confident, Firm, Deep              |
| `shelby`    | Shelby    | Female | Moderate Southern Accent            | Friendly, Reassuring, Twangy       |
| `mason`     | Mason     | Male   |                                     | Casual, Patient, Mellow            |
| `virginia`  | Virginia  | Female |                                     | Approachable, Empathetic, Friendly |
| `eleanor`   | Eleanor   | Female |                                     | Grounded, Patient, Reassuring      |
| `gabrielle` | Gabrielle | Female |                                     | Calm, Reassuring, Velvety          |
| `paula`     | Paula     | Female |                                     | Approachable, Grounded, Smooth     |
| `nolan`     | Nolan     | Male   |                                     | Confident, Direct, Professional    |
| `roberto`   | Roberto   | Male   | Moderate Spanish (Mexico) Accent    | Casual, Confident, Suave           |
| `hikari`    | Hikari    | Female | Moderate Japanese Accent            | Upbeat, Soft-spoken, Light         |
| `tomoya`    | Tomoya    | Male   |                                     | Steady, Gravelly, Patient          |
| `eloise`    | Eloise    | Female | Moderate British Accent             | Bright, Confident, Polished        |
| `jerome`    | Jerome    | Male   | Moderate French Accent              | Cheerful, Expressive, Professional |
| `daniela`   | Daniela   | Female | Moderate Portuguese (Brazil) Accent | Bright, Confident, Precise         |
| `juliana`   | Juliana   | Female | Slight Portuguese (Brazil) Accent   | Calm, Friendly, Smooth             |
| `valeria`   | Valeria   | Female | Slight Spanish (Colombia) Accent    | Cheerful, Direct, Polished         |
| `eduardo`   | Eduardo   | Male   | Slight Spanish (Mexico) Accent      | Approachable, Patient, Serious     |
| `henri`     | Henri     | Male   |                                     | Deliberate, Firm, Flat             |
| `kourtney`  | Kourtney  | Female |                                     | Clear, Friendly, Upbeat            |
| `kaspar`    | Kaspar    | Male   | Slight German Accent                | Patient, Reassuring, Chill         |
| `mei`       | Mei       | Female |                                     | Clear, Patient, Upbeat             |
| `stella`    | Stella    | Female |                                     | Bright, Clear, High-pitched        |
| `karoline`  | Karoline  | Female | Moderate German Accent              | Crisp, Direct, Grounded            |
| `amelia`    | Amelia    | Female | Moderate British Accent             | Cultured, Monotone, Professional   |
| `william`   | William   | Male   | Moderate British Accent             | Confident, Brisk, Monotone         |
| `joon`      | Joon      | Male   |                                     | Grounded, Approachable, Patient    |
| `hana`      | Hana      | Female |                                     | Calm, Light, Smooth                |
| `mia`       | Mia       | Female | Moderate Australian Accent          | Chill, Friendly, Twangy            |
| `derek`     | Derek     | Male   | Moderate Australian Accent          | Confident, Deep, Serious           |
| `divya`     | Divya     | Female | Moderate Indian Accent              | Cheerful, Clear, Precise           |
| `alice`     | Alice     | Female |                                     | Peaceful, Mellow, Approachable     |
| `karin`     | Karin     | Female | Moderate South African Accent       | Direct, Friendly, Steady           |
| `phillip`   | Phillip   | Male   |                                     | Empathetic, Professional, Friendly |
| `jackson`   | Jackson   | Male   |                                     | Gravelly, Confident, Chill         |
| `gina`      | Gina      | Female |                                     | Bright, Cheerful, Smooth           |
| `michelle`  | Michelle  | Female |                                     | Deep, Serious, Measured            |

> **Note**
>
> This page lists Phonic's base voices. Custom voices provisioned for your workspace also appear in [`voices.list`](/api-reference/voices/list) and can be used the same way.