#!/bin/sh
# Synthetic caller speech only; no recorded microphone audio or credentials.
set -eu
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != Darwin ]; then
  echo "Generate these synthetic WAV fixtures on macOS and copy priv/browser/test-audio/ to Linux."
  exit 1
fi
mkdir -p priv/browser/test-audio
say -v Samantha -r 165 --file-format=WAVE --data-format=LEI16@24000 -o priv/browser/test-audio/draft.wav 'For order one hundred twenty four, change the delivery instructions to leave it at reception.'
say -v Samantha -r 165 --file-format=WAVE --data-format=LEI16@24000 -o priv/browser/test-audio/refuse.wav "No, don't save that. Keep the original instructions."
say -v Samantha -r 165 --file-format=WAVE --data-format=LEI16@24000 -o priv/browser/test-audio/items.wav 'What items are in order one hundred twenty three?'
say -v Samantha -r 165 --file-format=WAVE --data-format=LEI16@24000 -o priv/browser/test-audio/package.wav 'For order one hundred twenty four, leave the package at reception.'
say -v Samantha -r 165 --file-format=WAVE --data-format=LEI16@24000 -o priv/browser/test-audio/correct.wav 'Actually, leave it with the neighbor.'
say -v Samantha -r 165 --file-format=WAVE --data-format=LEI16@24000 -o priv/browser/test-audio/interrupt.wav 'Wait! What items are in order one hundred twenty four?'
echo 'Generated six synthetic caller clips. Run ORDER_DESK_RECORDED_INPUT=1 scripts/browser.sh in the development environment.'
