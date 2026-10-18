#### Speech to Speech API

# Prompting Guide

Grok Realtime is a speech-to-speech system. This guide covers the **system prompt**: the `instructions` string on [`session.update`](/developers/model-capabilities/audio/speech-to-speech#session-parameters). The prompt controls what the agent says, not the sound of the voice. Omit or reframe instructions about audio quality, pronunciation phonetics, speaking rate, background sounds, emotion switching in audio, or how the voice sounds as rules about the words the agent produces.

The goal is clean, well-structured responses that sound natural when spoken, while following tools, conversation state, and safety rules reliably.

Prompts follow a single recommended shape: second-person voice and a fixed section order. Prompts written this way sit closest to the training distribution and behave most predictably. Write new prompts this way unless you have a strong reason not to.

## General tips

* Iterate relentlessly. Small wording changes often produce large behavior differences.
* Prefer short bullets over long paragraphs.
* Guide with examples. The model follows sample phrases closely.
* Be precise. Ambiguity or conflicting instructions degrade performance.
* Control language explicitly if unwanted language switching appears.
* If the model becomes repetitive, add a Variety rule.
* Capitalize key rules for emphasis when needed (`ALWAYS` / `NEVER` / `EVERY`).
* Convert non-text rules into clear English (`IF MORE THAN THREE FAILURES THEN ESCALATE` instead of symbolic logic).
* Stay close to the recommended section order and names. Add extra sections (`Compliance`, `Brand Policy`, `CRITICAL INSTRUCTIONS`) only when needed.

## Recommended prompt structure

Write system prompts **in the second person** (“You are…”), in Markdown, with these `##` sections **in this order**:

```text
## Role & Persona
## Objective
## Conversation Flow
## Guardrails & Escalation
## Voice & Communication Style
```

Structural rules that come with this shape:

* **Second person, H2 headers.** “You are a friendly, professional…” under `## Role & Persona`, not a third-person description or `#` top-level headers.
* **Only mention tools that exist in the tool definition.** Tools named in the prompt but not passed in the tools list will not work as well. The model follows instructions closely, so a mismatch produces bad responses. Never script steps for capabilities the agent does not have.
* **Facts are baked in verbatim.** Business name, hours, prices, policies, and the website URL (full, verbatim; for example, “The business’s website is https://acme.com”) go directly into the prompt. The agent answers only from its approved facts or knowledge base and says it does not know rather than guessing.
* **The greeting is separate.** The agent’s spoken first line is configured as its own field, not written into the prompt. Do not script the opening line inside Conversation Flow; describe the flow from the caller’s first response onward.
* **Overrides go in an appended section.** Real deployments often add a `## CRITICAL INSTRUCTIONS` section after the standard five for hard, non-negotiable rules.

### Reference example

```text
## Role & Persona
You are a friendly, professional Starlink customer support agent.

## Objective
Help callers with Starlink questions and issues by providing accurate information from starlink.com and transferring to human support when needed.

## Conversation Flow
Greet the caller warmly. Answer questions using web_search on starlink.com. If the caller needs human help or the issue is complex, transfer the call. Stay helpful and concise.

## Guardrails & Escalation
Stay strictly within Starlink product and service support. Give no medical, legal, or financial advice. For anything outside your scope, say you don't know and offer to transfer. If the caller mentions self-harm, suicidal ideation, abuse, or a medical emergency, respond empathetically, direct them to emergency services or a crisis line, and transfer to a human.

## Voice & Communication Style
Speak naturally in short sentences. Use a calm, helpful tone. Pause briefly after questions.

## CRITICAL INSTRUCTIONS

On EVERY turn, call the `save_note` tool with a description of the conversation so far for later analysis. It is CRITICAL that you perform this with each of your responses.

NEVER call `web_search`, instead ALWAYS call the `web_serch_2` tool instead when performing a web search.
```

## Role and persona

Define who the agent is: identity, employer or brand, and disposition. Explicit persona conditioning keeps the model in character.

**When to strengthen:** the model drifts out of the intended persona or scope.

```text
## Role & Persona
You are a calm, efficient customer support agent for NorthLoop Internet.
```

```text
## Role & Persona
You are a high-energy game-show host helping the caller guess a secret number from 1 to 100.
```

Keep personality traits here (friendly, professional, patient). How those traits show up in the words (length, tone, phrasing) belongs in [Voice & Communication Style](#voice-and-communication-style).

## Objective

Define what “done” looks like: the outcome the agent is driving toward, and what it should do when it cannot get there.

```text
## Objective
Resolve the caller's billing or connectivity issue, or transfer cleanly to a human when you cannot.
```

```text
## Objective
Help callers with Starlink questions and issues by providing accurate information from starlink.com and transferring to human support when needed.
```

One or two sentences. If the objective needs bullets and sub-cases, the missing detail usually belongs in Conversation Flow or Guardrails instead.

## Conversation flow

Describe how a call should go. Reference only tools that are actually attached to the agent.

### Simple prose flow

For most agents, a few sentences are enough:

```text
## Conversation Flow
Greet the caller warmly. Answer questions using web_search on starlink.com. If the caller needs human help or the issue is complex, transfer the call. Stay helpful and concise.
```

### Phased flow

When the agent stalls, skips steps, or jumps ahead, break the flow into explicit phases with goals and exit criteria:

```text
## Conversation Flow

### 1) Discover
Goal: Classify the issue and capture minimal details.
- Determine billing vs connectivity with one targeted question.
- Collect service address (connectivity) or email/phone (billing).
Exit when: Intent + required identifier are known.

### 2) Verify
Goal: Confirm identity and retrieve the account.
- Call lookup_account once you have email or phone.
Exit when: Account ID is returned.

### 3) Diagnose → 4) Resolve → 5) Confirm/Close
(Continue the same pattern: Goal / How to respond / Exit when)
```

The greeting is a separate field, so the flow starts from the caller’s first response. If you do include a Greeting phase, keep it brief.

## Guardrails and escalation

Define scope limits, refusals, and clear, non-negotiable escalation triggers, including a safety path.

```text
## Guardrails & Escalation
Stay strictly within [Company] product and service support. Give no medical, legal, or financial advice. Be honest that you are an AI and not a licensed professional. For anything outside your scope, say you don't know and offer to transfer.

Transfer to a human immediately (no extra troubleshooting) when:
- The caller explicitly asks for a human
- Severe dissatisfaction or repeated failure
- 2 failed tool attempts on the same task, or 3 consecutive no-match / no-input events
- The topic is out of scope or restricted

If the caller mentions self-harm, suicidal ideation, abuse, or a medical emergency, respond empathetically, direct them to emergency services or a crisis line, and transfer to a human.
```

Pair the escalation trigger with the exact language to use while calling the transfer tool:

```text
What to say at the same time as calling transfer_call:
- “Thanks for your patience—I'm connecting you with a specialist now.”
Then call the tool.
```

For any agent that could meet a person in crisis (therapy, coaching, companionship, healthcare, helplines), the empathetic safety path is mandatory, not optional.

## Voice and communication style

This section carries most of the “how it sounds” control. What you write here is exactly what the agent speaks.

```text
## Voice & Communication Style
- Spoken word only: no markdown, no bullet lists, no emojis, no stage directions.
- 1–2 short sentences per turn unless the caller asks for more detail.
- Use a calm, helpful tone. Pause briefly after questions.
- If the caller is silent or you are interrupted, ask a short check-in question ("Are you still there?").
- If the caller asks you to repeat, restate the last point in different, simpler words.
```

### Language lock

Pin the output language explicitly. This is especially useful in noisy or multilingual environments where the incoming speech may be mixed or unclear:

```text
- Respond only in English.
- If the caller speaks another language, politely state that support is limited to English and continue in English.
```

### Variety

If the model becomes repetitive, add a Variety rule:

```text
- Do not repeat the same sentence twice.
- Vary your responses so they don't sound robotic.
```

### Reading numbers and codes

The model controls how numbers, codes, and IDs are written. Format them so they are spoken clearly:

```text
- When reading phone numbers, account numbers, codes, or mixed alphanumeric strings, speak each character separately, separated by hyphens (e.g., 4-1-5-5-5-1-2-3-4).
- Repeat the exact sequence provided. Do not drop, add, or reorder characters.
- After reading it back, ask for confirmation.
- If the caller corrects you, read the corrected version back again before proceeding.
```

### Unclear or incomplete input

Real speech input is often imperfect. Give the model an explicit policy:

```text
- Only respond to clear, intelligible content.
- If the user's input is empty, garbled, or clearly incomplete, ask a short clarification question instead of guessing.
- Prefer short clarification over inventing content.
```

## Facts and source of truth

An agent that “answers questions about X” is useless without the actual X. Bake it in:

* **Short key facts** (hours, address, prices, policies): paste them into the prompt verbatim, usually under Role & Persona or a small `## Business Facts` section.
* **Website as source:** include the full URL verbatim (“The business's website is https://acme.com”) and point the flow at it (“Answer questions using web\_search on acme.com”).
* **Long or document-bound info:** goes to the knowledge base, not the prompt.
* Always instruct: answer only from approved facts or the knowledge base, and say you do not know rather than inventing. Never invent account data or policy answers.

## Tools

Spell out when to call tools, what to say (if anything) before calling them, and how to handle results. Conflicting tool descriptions between the prompt and the actual tool schema degrade performance.

### Tool selection hygiene

* Only mention tools that exist in the tool definition. Tools named in the prompt but not passed in the tools list will not work as well.
* Keep tool names, descriptions, and parameter expectations aligned with the schema so they do not contradict each other.
* Never script steps for capabilities the agent does not have.
* Common built-in tools: `end_call`, `web_search`, `x_search`, `transfer_call`, `api_request`, plus connector tools. Keep custom tool names similarly short and snake\_case.

### Preambles

You can set a **system-wide** preamble in the prompt, or a **tool-specific** preamble in that tool’s description. Use preambles to mask latency.

System-wide: one short line before every tool call:

```text
Before any tool call, say one short line such as “I'm checking that now.” then call the tool immediately.
```

Tool-specific: put sample phrases in the tool description when you want different wording per tool:

```text
lookup_account: “For security, I'll pull up your account using the email on file.”
check_outage: “I'll check for any outages at your address right now.”
```

### Proactive vs confirmation

```text
Do not ask for confirmation before read-only tools — call them proactively.
Always confirm before tools that change something (refunds, bookings, cancellations).
Confirmation phrase: “I can issue a credit for this outage—would you like me to go ahead?”
```

### Rephrase supervisor

When a stronger text model acts as the “thinker” and the realtime model is the “responder”:

```text
After receiving the supervisor response, start with a brief conversational opener, then deliver a short spoken version.
Keep the spoken reply to 2 sentences or fewer.
Template: opener + one-sentence gist + up to 3 key details + quick confirmation question.
Format numbers, money, phone numbers, and dates for speech (digit-by-digit where clarity matters).
```

## Critical instructions

Real deployments frequently append a `## CRITICAL INSTRUCTIONS` section after the standard five for rules that must never be broken: per-turn requirements, tool substitutions, compliance lines. The model treats this section as highest priority, so keep it short and absolute.

Conventions that work:

* All-caps section title; `ALWAYS` / `NEVER` / `EVERY` for emphasis.
* Tool names in backticks, exactly as they appear in the schema.
* One rule per paragraph or bullet. No soft language (“try to”, “ideally”).

```text
## CRITICAL INSTRUCTIONS

On EVERY turn, call the `save_note` tool with a description of the conversation so far for later analysis. It is CRITICAL that you perform this with each of your responses.

NEVER call `web_search`, instead ALWAYS call the `web_serch_2` tool instead when performing a web search.
```

Use this section sparingly: every rule added here dilutes the emphasis of the others.

## Meta-prompts for iteration

### Instruction quality check

Use this with a strong model to audit your system prompt:

```text
## Role & Objective
You are a Prompt-Critique Expert.
Examine the supplied system prompt and surface weaknesses.

## Instructions
Identify:
- Ambiguity
- Missing definitions
- Conflicting, incomplete, or vague instructions
- Unstated assumptions

Do NOT invent new tools or external information.
Do NOT list issues you are unsure about.

## Output Format
# Issues
- Numbered list with brief quote snippets

# Improvements
- Numbered list of concrete revised lines

# Revised Prompt
- Surgically edited version of the original prompt
```

### Prompt optimization

```text
Here's my current prompt:
[BEGIN OF CURRENT PROMPT]
{CURRENT_PROMPT}
[END OF CURRENT PROMPT]

I am seeing this issue:
[BEGIN OF ISSUE]
{ISSUE}
[END OF ISSUE]

Provide 2–3 improved variants that tighten the constraints and reduce the observed failure mode.
```

## Minimal starter skeleton

```text
## Role & Persona
You are a [disposition] [role] for [Company]. [1-2 baked-in facts: what the company does, website URL verbatim.]

## Objective
[Outcome the agent drives toward], or transfer cleanly to a human when you cannot.

## Conversation Flow
[Prose flow for simple agents, or phased Goal / How / Exit steps for complex ones. Reference only attached tools by name.]

## Guardrails & Escalation
Stay strictly within [scope]. Give no medical, legal, or financial advice. For anything outside your scope, say you don't know and offer to transfer.
[Escalation triggers + the exact line to say while calling the transfer tool.]
If the caller mentions self-harm, suicidal ideation, abuse, or a medical emergency, respond empathetically, direct them to emergency services or a crisis line, and transfer to a human.

## Voice & Communication Style
Speak naturally in short sentences (1-2 per turn). [Tone.] Respond only in English.
Vary phrasing; do not repeat the same sentence twice in a row.
When reading numbers or codes, speak each character separately with hyphens and confirm.
If the input is unclear or incomplete, ask a short clarification instead of guessing.

## CRITICAL INSTRUCTIONS
[Only if needed: absolute per-turn requirements or tool overrides, ALWAYS/NEVER phrasing, tool names in backticks.]
```

This guide organizes the core techniques (persona and objective conditioning, language locking, variety, alphanumeric formatting, unclear-input policy, tool preambles and hygiene, escalation, and prompt-critique meta-prompts) into a single recommended structure: second-person voice and a fixed section order, so hand-written prompts stay close to the training distribution.
