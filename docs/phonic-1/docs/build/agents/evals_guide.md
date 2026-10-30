> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

Phonic gives you two structured ways to know how your agent is doing: **extraction schemas** turn transcripts into typed data, and **conversation eval prompts** grade each call against plain language criteria.

## Extraction schemas: typed data from every call

Define a schema with typed fields, and then run it against conversations to get structured records. Examples include the caller's intent, whether they booked, the order number they gave, or a 1–5 satisfaction estimate.

1. Create the schema via the [extraction schemas API](/api-reference/extraction-schemas/create). Favor enums and booleans over strings wherever the domain allows:
   `booking_outcome: "booked" | "declined" | "callback"`
2. Run it per conversation with the [extractions endpoint](/api-reference/conversations/extract-data). We recommend using the `conversation.ended` webhook to be able to trigger your extractions immediately.
3. Read results back and store them with your own records.

What's important to know:

* Extractions read the transcript, so if you have a data-retention policy, run them promptly before transcripts are deleted.
* You can also set up your system to run extractions by the project's conversation list on a timed interval, and running extractions on all new conversations. However, keep your retention policy in mind, as noted above.

## Conversation eval prompts: plain-language grading

Eval prompts live at the project level: a `name` and a criterion written in plain language, evaluated per conversation.

> "The assistant stated the recording disclosure at the beginning of the conversation."

> "The assistant offered the caller a callback time when no appointment was available."

1. Create prompts via the [projects eval-prompts API](/api-reference/projects/create-eval-prompt).
2. Evaluate a conversation against them with the [evaluate endpoint](/api-reference/conversations/evaluate).
3. Read results back per conversation, or listed across the project.

Tips that make criteria useful:

* **Make each criterion binary and observable.** "The assistant was helpful" is difficult to judge, but "the assistant offered at least one alternative slot after saying no availability" is a yes or no that two people reading the transcript would agree on.
* **One behavior per prompt.** Criteria with multiple components ("greeted warmly and verified identity and offered the discount") make it difficult to evaluate if the agent behaved correctly.
* **Write criteria for your failure modes**. Encode the mistakes you've actually seen in transcripts.
* **Prepare for "undecided" verdicts.** The grader returns undecided when it can't determine the outcome from the transcript, including calls where the behavior never had an occasion to occur. Track the rate per criterion to determine if the criterion's wording is observable or if agents regressed.

### A worked example

Criteria for the restaurant reservations agent from the [prompting guide](/docs/build/agents/prompting_guide)'s worked example. Write one per *behavior*: a rule that both requires something and rules something out becomes two criteria, as the allergen rule does here.

> "If the caller asked about allergens or dietary restrictions, the assistant offered a callback from the kitchen."

> "If the caller asked about allergens or dietary restrictions, the assistant left the allergen question to the kitchen rather than confirming a dish was allergen-free."

> "For a party larger than eight, the assistant transferred the caller to the events line instead of booking."

> "When no tables were available, the assistant offered the waitlist and did not invent times."

> "The assistant confirmed the date, time, and party size back to the caller before ending the call."

Each one is binary, observable, and covers a single behavior traceable to a rule in the system prompt. When one fails, you know exactly which aspect of the prompt to strengthen.

## The improvement loop

The two mechanisms compose into a quality process:

1. Extraction schemas tell you **what happened** on every call (outcomes, at scale).
2. Eval prompts tell you **whether the agent behaved** (criteria, per call).
3. When an eval criterion fails repeatedly, iterate on the system prompt (see the [prompting guide](/docs/build/agents/prompting_guide)).
4. Re-run the evals on new calls. If the number moved, keep the change.

### Test a fix before shipping it

When a criterion fails on a specific call, you don't have to redeploy to try a fix. Open the failing turn in the **prompt playground** (in the conversations view, click the menu next to a turn), or call the [replay endpoint](/api-reference/conversation-items/replay) directly with an edited `system_prompt` and `num_responses` (up to 200): it returns the alternative responses the assistant would have produced for that turn under your candidate prompt. To test beyond a single turn, [replay the entire recorded conversation](/api-reference/conversations/replay) through an updated agent. See [Replaying Conversations](/docs/build/agents/replay) for the full workflow.

A replay that fixes the failing turn is evidence the change helps, not proof. The fix still needs to hold on live calls, so deploy it and re-run your evals on new conversations.

Grade a set of real conversations before and after every significant prompt change, so you iterate on evidence rather than anecdotes. If you use [Braintrust](https://www.braintrust.dev), enable the integration by setting `observability_integrations: ["braintrust"]` on the [agent](/api-reference/agents/create): conversations stream into your Braintrust project, where experiments can compare the before-and-after sets side by side.

## Evaluating conversation flow beyond the transcript

Eval prompts read the transcript, so they grade everything visible in text: whether the agent followed the flow, asked one question at a time, repeated itself, or talked past a request.
The [conversation analysis webhook](/docs/build/with-webhooks/post-call-webhooks/conversation-analysis) reports per-turn latencies and interruption count to assist you with evaluating voice-specific signals.