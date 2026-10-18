'use strict';
function assertSessionOpen(state, events) {
  if (!state || (!state.closed && state.status.status === 'ready')) return;
  const overflow = [...events].reverse().find(e => e.event === 'audio_discontinuity' && e.source === 'provider' && e.payload?.cause === 'output_overflow');
  const reason = overflow ? 'provider output_overflow' : `session ${state.status.status}`;
  throw new Error(`Call ended before the acceptance condition: ${reason}`);
}
module.exports = {assertSessionOpen};
