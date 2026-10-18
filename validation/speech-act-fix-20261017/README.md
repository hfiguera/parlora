# Speech-act arbitration fix — October 17, 2026

The OrderDesk interpreter no longer lets a tentative `presence` label override a
confident read and erase its known target. The fallback is limited to status,
items, instructions, progress, retries, and read continuations. Ordinary intent,
target and addition/replacement checks still run. A continuation may reuse its
admitted target only through the existing continuation guard.

Confident presence remains independent of intent/target probabilities and does
not answer a pending business clarification. Uncertain writes, acknowledgments,
refusals, cancellations, delivery restatements and relationship replies retain
their previous conservative treatment. The 0.8 selected-probability gate and
pinned `jev-1.13.0` remain unchanged. Original model answers remain in evidence.
Parlora's library, providers, channels and backends are unchanged.

## Before/after verification

Four focused tests failed before the implementation change, including the
end-to-end completed-items suffix case. See [before-fix output](results/tests-before.log).
The tests now cover captured 0.55/0.46 presence probabilities, running/completed
reads, admitted target reuse, new operations, corrected targets, uncertain required
fields, confident presence during clarification, and non-read safeguards.

The existing coordinator test replays the conflict through real session/provider/
Jido interfaces: completed items for 825, trailing "there", a new saved-instructions
read, then correction to 124. It verifies accepted results, no duplicate lookups,
no unnecessary clarification, and claimed delegations.

The final packaged consumer passed **230 tests**. The 26 focused tests also passed
with seeds 0, 317 and 999 using two schedulers. See the [packaged build log](results/packaged-consumer.log)
and [summary/source hashes](results/summary.json). Compilation treats application warnings
as errors; formatting is checked. The package contains the actual Parlora source
distribution, and its release smoke test runs outside Mix.

## Frozen-answer regression check

Both previous model comparison runs were replayed through the current real
`AppPolicy`, with exact structured-input equality checked before each classified
case. No API calls were made. Model fields identify the original observations.

| Original corpus | Before matches | After matches | Newly failing previously passing cases |
| --- | --- | --- | --- |
| [41 cases × 3 × 2 models](results/frozen-initial.json) | 235/246 | 243/246 | **0** |
| [43 cases × 3 × 2 models](results/frozen-expanded.json) | 247/258 | 247/258 | **0** |

All eight captured speech-act failures are repaired, including six completed-items
cases and two running-items cases. Other earlier failed model judgments remain
failed; they are not silently promoted. The strict replay command therefore exits
nonzero on those known failures even though `newly_failed` is zero. Raw original
inputs and answers are retained in the [model evaluation](../jev-1.14-20261017/README.md).

## Presence controls and prompt choice

A proposed speech-act prompt explicitly described read suffixes. It was **not
adopted**: [paired live requests](results/prompt-comparison.json) showed that it
classified a genuine "Are you there?" after an unfinished read as ordinary speech
on all three attempts. Original wording recognized presence on all three. Both
wordings handled the actual items suffix correctly with the fixed arbitration.

The final question-generation source is byte-identical to `7e0c409`; the production
fix changes arbitration only. This avoids changing model request semantics while
fixing the deterministic handling of captured uncertain answers. The proposed
question is preserved as a [rejected experimental fixture](../jev-1.14-20261017/proposed-speech-act-question.json).
The [paired runner](../jev-1.14-20261017/presence_prompt_check.exs) accepts the original
interpreter source, proposed-prompt live observations and a new output path.
The [initial proposed-prompt run](results/proposed-prompt-live.json) is retained.

## Final live validation

[46 fixed synthetic dialogues × 3 attempts](results/final-live.json) were evaluated
against live pinned `jev-1.13.0`, without cache or automatic retries. These evaluate
typed judgments and policy proposals, not acoustic playback or backend execution.

| Area | Passing attempts |
| --- | --- |
| Presence/audibility, mixed business, no prior order, incomplete prior read, pending clarification | 21/21 |
| Admitted read and retry continuations | 15/15 |
| Initial requests and operation changes after completed work | 21/21 |
| Explicit numeric/spoken corrections and corrections changing operation | 12/12 |
| Delayed numeric prefix correction (`120` + `three`) | 1/3 |
| All other cases | 66/66 |
| **Total** | **136/138** |

The two remaining failures are the previously observed addition/replacement
uncertainty for a delayed numeric correction: the model identifies order 123, but
replacement receives 0.79/0.77 rather than the required 0.8. Neither failure is a
presence override. Those gates remain intact; no incorrect-order work is admitted.
Live scores vary, so the frozen comparison supplies the direct evidence of no
new failures caused by arbitration. This is not a guarantee for every future
hosted-model response. JEV 1.14.0 migration remains held for its separate recorded
regressions.

## Reproduction

Run ordinary tests and consumer/release validation with `scripts/consumer.sh`.
From that consumer, replay saved model answers without credentials:

```sh
mix run scripts/semantic_judgment_report.exs /tmp/speech-act-replay.json \
  --models jev-1.13.0,jev-1.14.0 --repeats 3 \
  --replay /ABSOLUTE/PARLORA/validation/jev-1.14-20261017/results/initial-comparison.json
```

Repeat with the saved `comparison.json` for the expanded corpus. The JSON records
the prior outcome, new outcome, verified input, raw answers and newly failed count.
The documented Keychain-assisted live command in OrderDesk's README evaluates all
46 current cases; use a separate database and a new output file.
