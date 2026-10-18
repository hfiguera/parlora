'use strict';
// Backend completion and actual reply checks remain separate. An unconfirmed
// submission is eligible only for a provider that explicitly lacks remote ACKs.
function resultDelivered(state, job) {
  return job.delivery === 'accepted' ||
    (state.status['context_acknowledgment?'] === false && job.delivery === 'unconfirmed');
}
module.exports = {resultDelivered};
