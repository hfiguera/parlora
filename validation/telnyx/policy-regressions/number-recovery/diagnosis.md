# Number correction diagnosis

Latest manual call: lA7ZbtLhgxA1W4zvoF4FA0uw.
Original deltas: 120 arrived at 17.950 s, status task for 120 submitted at
18.323 s, and trailing three arrived at 18.867 s. Thus admission was 373 ms
after the numeric prefix and 544 ms before its continuation. The task finished
and returned not found. Two later clear repetitions of 123 never produced work.

Deterministic parser checks in number-root-cause.log show numeric 120 does not
count as open, and a mixed 120 three is still extracted as 120 plus an incomplete
spoken tail. Completion reconstruction only supports spelled-out prefixes.

Reconstructed live TypeSafe replays (not original retained model judgments)
reproduce clarification for both later replies even when segmented cleanly with
123 offered as a candidate. Cardinal: intent .75 / target .72. Digit sequence:
intent .63 / target .69. Both fail the unchanged .8 confidence policy. The app
sends all unhandled input since the 120 task, and does not describe the outstanding
clarification/reply relationship in its classifier contract. Bare-number recovery
is left to the general new-intent classifier.

Controls in number-cause-controls.log: trimming new_caller_text alone did not
resolve uncertainty; adding an unreferenced clarification field alone or together
also did not resolve it. An explicit new request (Sorry, check order 123) resolved
status at 1.0 and target at .95 with the same earlier history. Therefore this is
not merely an input-trimming fix: the policy needs explicit clarification-answer
semantics, along with numeric-prefix handling.

If overlapping transcript timestamps prevent segment separation, number_words
can also reject concatenated repetitions and omit 123 from candidates. That is a
separately reproduced vulnerability; original timestamps were not retained so
it is not claimed as the specific path of this call.

No implementation files changed during this diagnosis. Existing uncommitted
fixes for earlier issues remain in place.
