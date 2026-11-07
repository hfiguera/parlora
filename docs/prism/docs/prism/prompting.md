> ## Documentation Index
> Fetch the complete documentation index at: https://docs.rime.ai/llms.txt
> Use this file to discover all available pages before exploring further.

# Write instructions that Prism follows

> Start a Prism agent from a short system prompt, then improve it for your own calls with rubrics, a coding agent, and examples.

In this guide, you'll write the instructions (the system prompt) for a Prism agent, then improve them for your own calls. Prism works well with a short prompt, so start small, and let your test calls show you what to add.

## How Prism reads your prompt

Prism writes every reply from your instructions, your tools, and the conversation so far, and your caller hears every word. Keep these points in mind:

* **Everything is spoken:** markdown, lists, and symbols get read aloud, so ask for plain spoken sentences.
* **Replies follow your style:** if your instructions use headings and bullets, replies will too, so write them in plain sentences.
* **Tools need a rule:** Prism decides when to call a tool, so say when to use each one.

## General rules and scenario rules

Your instructions can hold two kinds of rules, and each needs different care:

* **General rules** work on any call, so every prompt can start with them. The rules for speech in the next section are general: they keep every reply easy to listen to.
* **Scenario rules** help one kind of call, and they can break others. Confirming names and numbers is one. It helps a booking line, but in a general assistant it can make Prism ask for names that nobody needs.

So put the general rules in every prompt, and add a scenario rule only to the prompt for the calls that need it.

## Write your first prompt

**1. Start with the rules for speech**

These three paragraphs are general rules, so they work on any call. They keep replies easy to listen to, and in our tests, they removed nearly all markdown, lists, and math notation from replies. Put them at the top of your instructions:

```text Rules for speech wrap theme={null}
You are an assistant on a live phone call. Everything you write is turned into speech and heard by the caller; nobody ever sees it as text.

So write only plain spoken sentences. Never use markdown: no asterisks, no bold or italics, no headings, no bullet points, no numbered lists, no tables. Never use math or logic notation such as LaTeX, dollar signs, arrows or symbols; say it in words instead. When you need to walk through steps, say them in ordinary sentences, using words like first, then, next and finally.

Respond naturally and conversationally, as you would on a real phone call, and try to be helpful.
```

**2. Add your agent's job**

After the speech rules, say in a few plain sentences who the agent works for, what it can do, and how long its replies should be. Give each tool one sentence that says when to call it. For example:

```text Your agent's job wrap theme={null}
You answer the phone for Juniper Cafe. You can tell callers the opening hours. Answer in two or three sentences, and ask one question at a time. Call get_opening_hours before you answer a question about opening hours.
```

In each tool's parameter descriptions, give the written form of the value, such as `18:30` for a time, because Prism hears the spoken form. And keep rules that must always hold, such as "book only after the caller confirms", in your tool code as well. Your prompt guides each reply, and your code makes sure.

**3. Try it on a call**

Connect with your instructions, as the [SDK quickstart](https://docs.rime.ai/docs/prism/quickstart.md) does, and talk to your agent.

> [!TIP]
>
> Talk the way your callers do. Pause in the middle of a sentence, and say "sure" instead of "yes". You'll quickly find where the prompt needs work.

## Add scenario rules

Add a scenario rule only to the prompt for the calls that need it. Then test your other kinds of call again, because a rule that fixes one kind can break another.

### Confirm names and numbers

For calls that collect names, codes, or account numbers, add this paragraph to your instructions. Prism then reads each value back and asks the caller whether it is right:

```text Read back names and numbers wrap theme={null}
When the caller gives a name, ID, code, tracking or confirmation number, email address, phone or account number, street address or city, your next reply reads it back and asks whether it is right.

Spell names, IDs, codes, tracking and confirmation numbers and emails letter by letter with dashes, for example "<L-E-T-T-E-R-S>" or "<X, 9, X, 9, X>".

Spell every name letter by letter, even a common one, for example "<FIRST NAME>, <F-I-R-S-T>, <LAST NAME>, <L-A-S-T>".

Say other numbers in groups of three or four digits, for example "<9 9 9, 9 9 9, 9 9 9 9>".

Say dates, times and amounts the usual way. Say streets and cities as words.

Do not call any tool with that value until the caller confirms it; if they correct it, use the corrected value.

Keep every other confirmation this business asks for, such as dates and amounts.

Tool arguments always use the written form: plain email, digits without spaces, names as words.
```

Leave it out of other prompts. In a general assistant, it can make Prism ask for the caller's name when nobody needs it. And even with the paragraph, Prism can call a tool before the caller answers. So for a tool that changes something, such as a booking, keep the confirmation rule in your tool code too.

## Improve it with a coding agent

Once your agent handles a call, improve the prompt in rounds, scored against your own scenarios. A coding agent such as Claude Code or Codex can run the rounds for you. It needs three things from you:

* **Scenarios:** the calls your agent should handle, such as a booking, a question it can't answer, and a caller who changes their mind.
* **A rubric for each scenario:** a few yes-or-no questions about the transcript, such as "Did the agent wait for the tool before it said the table was booked?"
* **A test command:** it runs each scenario a few times and saves the transcripts.

Then paste this request, with your own file names and test command:

```text Request for your coding agent wrap theme={null}
Improve the Prism instructions in instructions.txt.

The scenarios and their rubrics are in rubrics/. Each rubric item is a yes-or-no question about a call's transcript.
To test, run <your test command>. It runs each scenario 3 times and saves the transcripts.

Do 3 rounds. In each round, run the tests, grade every call against its rubric, and change one thing in the instructions to fix the most common failure. Keep the change only if the new version passes more rubric items than the old one, on the same scenarios.

Do not change the rubrics or the scenarios. After each round, report the change and the scores of both versions.
```

Score every scenario in each round, because a change that helps one kind of call can hurt another.

## Show examples

When a behavior is hard to describe, show it. Add a short example exchange to your instructions, or start the session with example turns, as [Start from an earlier conversation](https://docs.rime.ai/docs/prism/sessions.md#start-from-an-earlier-conversation) shows. Prism copies example turns closely, including whether they use a tool. So if an example reply depends on a tool, add the past tool call and its result before that reply. In our tests, with the past call in place, Prism called the tool for every question. Without it, Prism skipped the tool for most questions and guessed the hours.

## When prompting isn't enough

If your prompt and examples still don't get the behavior you need, we can fine-tune Prism on your calls. Write to [support@rime.ai](mailto:support@rime.ai).

## Next steps

Now that your prompt works, you can:

* [Set the phrase callers hear while a tool runs](https://docs.rime.ai/docs/prism/tools.md#set-the-phrase-for-a-tool), so there's no dead air.
* [Change the instructions and tools during a call](https://docs.rime.ai/docs/prism/sessions.md#update-instructions-or-history-during-a-call), so each stage of the call gets what it needs.
* [Tune how readily Prism ends a turn](https://docs.rime.ai/docs/prism/live-conversations.md#how-a-turn-ends), for callers who pause mid-sentence.


This documentation is built and hosted on [Mintlify](https://mintlify.com), a developer documentation platform.