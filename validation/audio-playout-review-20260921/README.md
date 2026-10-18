# Provider starvation / framework source review

See [the review](../../docs/audio-playout-review.md) for conclusions, pinned
Pipecat/LiveKit source links, proposed policy comparisons and validation limits.

`trace-excerpts.json` retains original numeric events around gaps 18, 21 and 22
from session `qwG2z6uev34tB36d9VeK1mZl`, running Parlora `78b1192` on macOS.
It contains no raw speech or credentials. Each window begins 400 ms before
the recorded queue-empty observation and extends at most 20 ms past resumption.
These are selected excerpts, not a whole-call recording.

Recompute the review's timing table from the repository root:

```sh
python3 validation/audio-playout-review-20260921/analyze.py
```

The analyzer checks 100 ms PCM packet sizes and the gap-duration decomposition.
First admission is the first observed channel frame after packet receipt;
it is not a per-packet completion measurement. The saved observations do not
distinguish provider generation delay from network delay before receipt.

This review did not run Pipecat or LiveKit, benchmark replacement policies,
record the receiver, change production code, or certify audible quality.
