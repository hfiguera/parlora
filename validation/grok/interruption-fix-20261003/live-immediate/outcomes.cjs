'use strict';
const {resultDelivered} = require('../acceptance/delivery.cjs');
const assert = require('node:assert/strict');
const {checkReply} = require('./replies.cjs');

function assistantText(evidence, since) {
  return evidence.events.filter(e => e.type === 'transcript' && e.payload?.speaker === 'assistant' &&
    e.observed_at_ms >= since).map(e => e.payload.delta || '').join('');
}
function resultBoundary(evidence, state, target, operation) {
  const current = Object.entries(state.status.jobs).find(([id, job]) => job['current?'] &&
    resultDelivered(state, job) && state.jobs[id]?.input.order === target && state.jobs[id]?.input.operation === operation);
  assert(current, 'No accepted current result');
  const event = evidence.events.find(e => e.event === 'request_completed' && e.request_id === current[0]);
  assert(event, 'Missing backend completion boundary for reply evaluation');
  return event.observed_at_ms;
}
function assessReply(text, pattern, numbers, target) {
  const matches = typeof pattern === 'string' ? checkReply(pattern, text) : pattern.test(text);
  const wrong = numbers.filter(n => n !== target);
  // Reject clear contradictions of the positive fixture facts. This is deliberately
  // bounded: unrelated facts and arbitrary paraphrases still require review.
  const contradiction = /\b(?:not|isn't|is not|aren't|are not|no)\b[^.!?]{0,25}\b(?:out for delivery|desk lamp)\b/i.test(text);
  // Fixture 124 has no ETA. Conservatively reject added dates in status answers;
  // this is a regression guard, not a general factuality classifier.
  const unsupported_timing = target === '124' && /out for delivery/i.test(text) &&
    /\b(?:today|tonight|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday|this (?:morning|afternoon|evening)|by \d|within \d)\b/i.test(text);
  return {matches, wrong_orders: wrong, contradiction, unsupported_timing,
    passed: matches && !wrong.length && !contradiction && !unsupported_timing};
}
async function expectReply(h, {since, pattern, target, label}) {
  const check = {kind: 'reply-check', label, since_ms: since, target, expected: String(pattern), status: 'pending'};
  h.evidence.checkpoints.push(check);
  try {
    await h.wait(async () => {
      await h.state(); // A closed call is a failure, not a 75-second caption wait.
      const text = assistantText(h.evidence, since);
      const latest = h.evidence.events.filter(e => e.type === 'transcript' && e.payload?.speaker === 'assistant' && e.observed_at_ms >= since).at(-1);
      check.observed_text = text;
      if (!latest || Date.now() - latest.observed_at_ms < 1000) return false;
      const response = await h.page.request.post(new URL('/__pilot/order-numbers', h.page.url()).href, {data: {text}});
      assert.equal(response.status(), 200);
      const {numbers} = await response.json();
      const assessment = assessReply(text, pattern, numbers, target);
      Object.assign(check, assessment, {last_caption_at_ms: latest.observed_at_ms});
      assert(!assessment.wrong_orders.length, `[incorrect-answer] Assistant named ${assessment.wrong_orders.join(', ')}; expected ${target}`);
      assert(!assessment.contradiction, '[incorrect-answer] Assistant contradicted the expected fact');
      assert(!assessment.unsupported_timing, '[incorrect-answer] Assistant added an unsupported delivery date');
      return assessment.passed;
    }, `[missing-answer] ${label}`);
    check.status = 'passed';
  } catch (error) {
    check.status = 'failed'; check.error = error.message;
    throw error;
  } finally {check.at_ms = Date.now();}
  return check;
}
module.exports = {assistantText, resultBoundary, assessReply, expectReply};
