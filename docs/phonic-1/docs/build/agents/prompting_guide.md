> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

This guide covers how to structure a system prompt so your voice agent works as well as a human. Phonic's models are post-trained for common voice-agent scenarios, and this guide helps you get the most out of them.

New to Phonic? Start with [Build Your First Agent](/docs/get-started/build-your-first-agent). It assembles a complete agent and carries the reference material on where each kind of rule goes. Language configuration has [its own page](/docs/build/agents/multilingual). This page covers how to structure and word the prompt itself.

## Structuring your system prompt

A good voice-agent prompt should be similar to a briefing for a new employee. You don't necessarily need every section below. Use what changes the outcome for your agent:

1. **Role and persona**: who the agent is, in one or two sentences: name, company, role, tone, personality.
2. **Task and call flow**: what a successful call accomplishes, as ordered steps: greet, identify the caller, find what they need, act, confirm, close. Models follow explicit sequences far more reliably than implied ones. With the conversation-ending tool enabled, the agent can end calls on its own when it thinks the conversation has been concluded. Prompts may add more control over how the agent decides when to end the call, and what should be said before ending the call ("confirm the appointment time before ending the call").
3. **Rules that always apply**: business policies and guardrails ("we never quote prices without a consultation", "always verify identity before discussing account details"). State each as a single testable sentence; these must hold on every call, which is why they live here and not in any tool's description (the placement reasoning is covered in [Build Your First Agent](/docs/get-started/build-your-first-agent#step-2-define-the-tools)).
4. **Tool orchestration**: the prompt carries what individual tool descriptions can't: ordering across tools within the call flow, prerequisites tied to the conversation as a whole ("confirm the reservation details back to the caller before ending the call"), and what to do with results ("if there are no open tables, offer the waitlist — never invent times"). Per-tool guidance (when and how to call one tool, its preconditions) belongs in that tool's description, written when you define the tool.
5. **Error handling and recovery**: what the agent says when things go sideways: the caller is silent, the answer is unintelligible, or a tool fails. Calls die in these moments, not on the happy path ("if the lookup fails, apologize, offer to take a callback number, and move on").
6. **Escalation**: the conditions that end with a transfer or callback, stated concretely ("if the caller mentions chest pain, transfer immediately — do not continue the assessment").
7. **Voice style**: only where your use case diverges from the defaults, see the [Voice Style Prompting](#voice-style-prompting) section for more.
8. **Example exchanges**: 2–3 short sample exchanges covering the happy path plus one edge case (no availability, an unclear caller). The model closely follows sample phrasing, so these are high-leverage. Mark them clearly as examples so they read as illustrations, not extra rules.

Per-call context (the caller's name, their plan, the reason for the call) doesn't belong hardcoded in the prompt. Use [template variables](/docs/build/agents/template-variables) so one agent serves every caller with the right details filled in at call time. Built-in system variables add the date and time, and `{{system_past_conversations_summary}}` gives the agent a recap of the caller's previous calls.

There is no target word count. Length tracks scope. Focused single-workflow agents typically run a few hundred to \~1,400 words; multi-workflow agents run longer. The structure above matters more as the prompt grows: short prompts behave similarly either way, but long, policy-heavy prompts follow ordered, sectioned rules measurably more reliably.

## A worked example

The prompt from the agent assembled in [Build Your First Agent](/docs/get-started/build-your-first-agent). Read it against the structure list above: every numbered section appears in order (role, flow, rules, tool orchestration, recovery, an example exchange):

```text
You are Sabrina, the host at Phantastic Phood, a restaurant. You are warm
but efficient — callers are often calling from work or on the go.

Your job on every call:
1. Greet the caller and ask what they need.
2. For reservations: get the date, time, and party size, check
   availability with check_availability, offer at most two options 
   until the caller chooses a time that works for them, and
   then book the slot with book_table.
3. Confirm the date, time, and party size back to the caller.
4. Once they confirm and have no other questions, say goodbye and end
   the call.

Rules that always apply:
- Never guarantee that a dish is allergen-free; offer to have the
  kitchen give them a call back instead.
- For parties larger than 8, transfer to the events line — do not book
  directly.
- Don't invent menu items or specials; if you don't know, say the menu
  changes seasonally and offer to have someone follow up.

Tools:
- If check_availability returns no open tables, offer the waitlist —
  never invent times.
- If a tool fails, apologize, offer to take a callback number, and move
  on. Never go silent while retrying.

If the caller goes quiet and doesn't respond to a check-in, let them
know you'll release the table request for now — they're welcome to
call back to finish the booking — then end the call politely.

Example exchange:
Caller: "Do y'all have anything Friday around seven? Party of four."
Sabrina: "Let me check that for you — one sec. ... I've got a 6:45 or a
7:30 on Friday for four. Want either of those?"
```

## Voice Style Prompting

Phonic's model is already optimized to sound natural in conversations. It will generally:

1. Keep responses short
2. Ask one question at a time
3. Often insert or speak with disfluencies, when natural
4. Understand and say numbers, emails, and phone numbers in natural spoken form

You should only need to add style rules for your specific use cases. Speaking mechanics such as the voice and its pace are set in [agent configuration](/docs/get-started/build-your-first-agent#step-3-configure-the-agent). See [voices](/docs/build/agents/voices) for the catalog.

### Spell-back confirmations

The letter-by-letter *format* is built in: when the agent spells something out, it uses caps with spaces ("M A R T H A"), and alphanumeric IDs like "BKDJ134" are read character by character automatically. What the prompt decides is *when* spelling happens. By default the agent spells only when confirming something easily misheard. If your flow must always confirm a detail, say so:

> After collecting the caller's email, spell it back to confirm.

For domain terms the agent should pronounce a certain way, use the [pronunciation dictionary](/docs/build/agents/pronunciation-dictionary) rather than prompt phonetics.

### Emotion

Our voices naturally carry emotion for a variety of contexts: brighter when greeting a customer, softer when apologizing. To steer them, use plain language in the persona and rules ("stay calm and reassuring, even when the caller is upset").

## Next Steps

When you change the prompt, measure the change: edit one thing at a time, grade a set of real conversations before and after, and use the agent's version history in the dashboard to revert if the numbers regress. The [evals guide](/docs/build/agents/evals_guide) shows how to grade conversations against plain-language criteria so prompt edits are driven by results.