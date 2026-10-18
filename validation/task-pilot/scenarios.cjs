'use strict';
const assert = require('node:assert/strict');
const {assistantText, assertUnsegmentedCaptionRows, resultBoundary, expectReply} = require('./outcomes.cjs');
const phrases = {
  status124: 'Check order one hundred twenty four.',
  digits124: 'Check order one two four.',
  status825: 'Check order eight hundred twenty five.',
  grouped825: 'Check order eight twenty five.',
  status123: 'Check order one hundred twenty three.',
  items124: 'What items are in order one hundred twenty four?',
  items123: 'What items are in order one hundred twenty three?',
  instructions: 'What are the delivery instructions for order one hundred twenty four?',
  missing: 'Can you check my order?', number: 'One two four.',
  incomplete: 'Check order one two', suffix: 'four.',
  paused: 'Check order one hundred twenty [[slnc 350]] four.',
  correction: 'Actually, I meant order one hundred twenty four.',
  back: 'No, sorry, go back to order one hundred twenty three.',
  followup: 'What items are in that order?',
  unknown: 'Check order nine nine nine.', retry: 'Please try checking that order again.',
  draft: 'For order one hundred twenty four, leave the package at reception.',
  refuse: "No, do not save that. Keep the original instructions.",
  neighbor: 'Actually, leave it with the neighbor.',
  approval: 'Yes, go ahead and save it.',
  sameCorrection: 'Great. Oh, sorry, I made a mistake. I mean order one hundred twenty four.',
  shortCorrection: 'No, one hundred twenty three.',
  changeWithoutWording: 'Please change the delivery instructions for that order.',
  humanNeighbor: "Let's change that. Put there, leave with my neighbor.",
};
const definitions = [];
const define = (id, goal, type, run) => definitions.push({id, goal, type, run});
const jobs = s => Object.values(s.jobs);
const order = d => d.orders.find(o => o.id === '124');
const outputText = h => {
  const start = h.evidence.checkpoints.filter(e => e.kind === 'input-start').at(-1)?.at_ms || 0;
  return assistantText(h.evidence, start);
};
function greetingOutputDrained(state) {
  const status = state?.status;
  const output = status?.health?.output_forwarded;
  // Generation/captions can finish while speech is still queued. Allow source
  // forwarding to settle before ordinary task input; this is not proof of sound
  // reaching a physical speaker. Interruption scenarios still overlap responses.
  return status?.provider_speech === 'idle' && output?.frames > 0 &&
    Number.isFinite(output.last_at_us) && Number.isFinite(status.observed_at_us) &&
    status.observed_at_us - output.last_at_us >= 500_000;
}
async function connect(h, mapping) {
  await h.connect(mapping);
  await h.wait(async () => {
    const last = h.evidence.events.filter(e => e.type === 'transcript' && e.payload?.speaker === 'assistant').at(-1);
    return last && greetingOutputDrained(await h.state());
  }, 'greeting generation and source output drain');
  h.evidence.checkpoints.push({kind:'greeting-wait-ended',at_ms:Date.now(),evidence:'provider_idle_and_source_quiet',source_quiet_ms:500});
}
async function answer(h, target, operation, pattern, count = 1) {
  const state = await h.accepted(target, operation, count);
  // Evaluate the response after this result completes, including follow-ups and
  // corrections. Earlier acknowledgments may legitimately mention the old order.
  await expectReply(h, {since: resultBoundary(h.evidence,state,target,operation),
    pattern, target, label: `${operation} ${target}`});
  h.evidence.checkpoints.push({kind: 'outcome', at_ms: Date.now(), target, operation, state, assistant_text: outputText(h)});
  return state;
}
function assertReplyOrder(numbers,target) {
  assert(numbers.every(n => n === target),`Assistant named a different order: ${numbers.join(', ')}; expected ${target}`);
}
function statusCase(id, phrase, target, pattern) {
  define(id, `Select ${target} and report its stored delivery status`, 'read', async h => {
    await connect(h, {items: phrase}); await h.play('items');
    const s = await answer(h, target, 'status', pattern);
    assert(jobs(s).every(j => j.input.order === target && j.input.operation === 'status'), 'Wrong target or operation');
    assert.equal(jobs(s).length, 1, 'Duplicate lookup');
  });
}
statusCase('01-cardinal-124', 'status124', '124', /out for delivery/i);
statusCase('02-digits-124', 'digits124', '124', /out for delivery/i);
statusCase('03-cardinal-825', 'status825', '825', /processing/i);
statusCase('04-grouped-825', 'grouped825', '825', /processing/i);
statusCase('23-supplied-estimate-123', 'status123', '123', /(?:expected|estimated)[^.!?]*Friday/i);
for (const [id, phrase, target, pattern] of [
  ['05-items-124','items124','124',/desk lamp/i],
  ['06-items-123','items123','123',/travel mug[\s\S]*coffee|coffee[\s\S]*travel mug/i],
  ['07-instructions-124','instructions','124','empty-instructions'],
]) define(id, `Read ${target} ${id.includes('instructions') ? 'instructions' : 'items'} and state the stored facts`, 'read', async h => {
  const operation = id.includes('instructions') ? 'instructions' : 'items';
  await connect(h, {items: phrase}); await h.play('items');
  const s = await answer(h, target, operation, pattern);
  assert(jobs(s).every(j => j.input.order === target && j.input.operation === operation), 'Wrong target or operation');
});
statusCase('08-not-found', 'unknown', '999', 'not-found');
define('09-missing-number', 'Ask for a number before lookup, then resolve 124', 'clarification', async h => {
  await connect(h, {items: 'missing', interrupt: 'number'}); await h.play('items');
  await h.wait(() => /order number|three.digit|number.*order/i.test(outputText(h)), 'ask for number');
  assert.equal(jobs(await h.state()).length, 0, 'Guessed a number');
  await h.play('interrupt'); await answer(h, '124', 'status', /out for delivery/i);
});
define('10-incomplete-number', 'Clarify the incomplete ID, then resolve its completion to 124', 'clarification', async h => {
  await connect(h, {items:'incomplete', interrupt:'suffix'}); await h.play('items');
  await h.wait(() => /finish|full|complete|three.digit|one more|last digit/i.test(outputText(h)), 'ask to finish ID');
  assert.equal(jobs(await h.state()).length, 0, 'Guessed an incomplete number');
  await h.play('interrupt'); await answer(h, '124', 'status', /out for delivery/i);
});
statusCase('11-paused-number', 'paused', '124', /out for delivery/i);
define('12-correction', 'Supersede 123 with 124; deliver the current result', 'correction', async h => {
  await connect(h, {items:'status123', interrupt:'correction'}); await h.play('items'); await h.submitted('123', 'status');
  await h.play('interrupt'); const s = await answer(h, '124', 'status', /out for delivery/i, 2);
  assert(jobs(s).every(j => ['123','124'].includes(j.input.order)), 'Unexpected intermediate ID');
  assert.equal(jobs(s).length, 2, 'Duplicate correction work');
  if (process.env.PILOT_SLOW_CORRECTION === '1') {
    const oldJob=jobs(s).find(j=>j.input.order==='123');
    assert(['submitted','cancelled'].includes(s.status.jobs[oldJob.id].status),'Old work finished before correction was observed');
    assert.equal(s.status.jobs[oldJob.id]['current?'],false,'Old revision remains current');
    h.evidence.checkpoints.push({kind:'slow-correction-superseded',at_ms:Date.now(),state:s});
    await h.pause(13000);
    const final=await h.state();
    assert.equal(jobs(final).length,2,'Work was replayed after the cancelled lookup deadline');
    assert(['stale','not_applicable'].includes(final.status.jobs[oldJob.id].delivery));
    await expectReply(h,{since:resultBoundary(h.evidence,final,'124','status'),pattern:/out for delivery/i,target:'124',label:'settled correction'});
    h.evidence.checkpoints.push({kind:'slow-correction-settled',at_ms:Date.now(),state:final});
  }
});
define('13-repeated-correction', 'Resolve 123 → 124 → 123 without extra targets or duplicate work', 'correction', async h => {
  await connect(h, {items:'status123', interrupt:'correction', correct:'back'});
  await h.play('items'); await h.submitted('123','status');
  await h.play('interrupt'); await h.submitted('124','status');
  await h.play('correct'); const s = await answer(h, '123', 'status', /shipped|Friday/i, 3);
  assert.equal(jobs(s).length, 3, 'Unexpected number of lookups');
  assert(jobs(s).every(j => ['123','124'].includes(j.input.order)), 'Unexpected intermediate ID');
});
define('14-followup-items', 'After status, interpret that order as 124 and fetch items', 'followup', async h => {
  await connect(h, {items:'status124', interrupt:'followup'}); await h.play('items'); await answer(h,'124','status',/out for delivery/i);
  await h.play('interrupt'); const s = await answer(h,'124','items',/desk lamp/i,2);
  assert.equal(jobs(s).length, 2, 'Duplicate work');
});
define('15-explicit-retry', 'Repeat a not-found read exactly once when asked', 'followup', async h => {
  await connect(h, {items:'unknown', interrupt:'retry'}); await h.play('items');
  await answer(h,'999','status','not-found');
  await h.play('interrupt'); const s = await answer(h,'999','status','not-found',2);
  assert.equal(jobs(s).length, 2, 'Retry did not run exactly once');
});
async function draftSetup(h, second) {
  const before = await h.dashboard();
  await connect(h, {package:'draft', interrupt:second}); await h.play('package');
  const draft = await h.draft(/^leave the package at reception[.!]?$/i);
  await h.accepted('124','delivery');
  assert.deepEqual((await h.dashboard()).orders, before.orders, 'Voice modified saved orders');
  return {before, draft};
}
define('16-draft-only', 'Create the exact reception draft for 124 without saving it', 'draft', async h => {await draftSetup(h, 'refuse');});
define('17-draft-refusal', 'Reject the exact draft by voice; preserve saved instructions', 'draft', async h => {
  const {before,draft} = await draftSetup(h,'refuse'); await h.play('interrupt');
  await h.wait(async () => (await h.dashboard()).proposals.some(p => p.id === draft.id && p.status === 'rejected'), 'draft rejected');
  await h.accepted('124','refuse',2);
  assert.deepEqual((await h.dashboard()).orders,before.orders, 'Refusal changed saved orders');
});
define('18-draft-correction', 'Create the exact neighbor draft as a distinct proposal without saving either', 'draft', async h => {
  const {before,draft} = await draftSetup(h,'neighbor'); await h.play('interrupt');
  const second = await h.draft(/^leave it with the neighbor[.!]?$/i); await h.accepted('124','delivery',2);
  assert.notEqual(second.id,draft.id); assert.deepEqual((await h.dashboard()).orders,before.orders);
});
define('19-spoken-approval', 'Spoken yes must not save a draft; browser confirmation remains necessary', 'write-boundary', async h => {
  const {before,draft} = await draftSetup(h,'approval'); await h.play('interrupt'); await h.pause(6000);
  assert.deepEqual((await h.dashboard()).orders,before.orders,'Spoken approval changed saved orders');
  assert((await h.dashboard()).proposals.some(p => p.id === draft.id && p.status === 'pending'));
  const since = h.evidence.checkpoints.filter(c => c.kind === 'input-start').at(-1).at_ms;
  await expectReply(h, {since, pattern:'browser-confirmation', target:'124', label:'explain how to confirm in the browser'});
});
define('20-browser-confirmation', 'Explicit browser confirmation saves the exact draft once', 'write-boundary', async h => {
  const {before,draft} = await draftSetup(h,'approval');
  // Reproduce the human sequence: wait for the draft prompt before clicking.
  const requested = h.evidence.checkpoints.filter(c => c.kind === 'input-start').at(-1).at_ms;
  await expectReply(h, {since:requested, pattern:'browser-confirmation', target:'124', label:'draft prompt before browser confirmation'});
  const since=Date.now();
  h.evidence.checkpoints.push({kind:'browser-confirmation',at_ms:since});
  await h.action(draft.id,'confirm');
  const after = await h.dashboard(); assert.equal(order(after).version,order(before).version+1);
  assert.equal(order(after).instructions,draft.instructions);
  assert.deepEqual(after.orders.filter(o => o.id !== '124'),before.orders.filter(o => o.id !== '124'));
  await expectReply(h, {since, pattern:'saved-reception', target:'124', label:'announce verified saved reception instructions'});
  assert.deepEqual((await h.dashboard()).orders,after.orders,'Saved state changed during announcement');
  const rows = await h.page.locator('#transcript p[data-speaker="assistant"]').evaluateAll(nodes => nodes.map(node => node.lastChild.textContent));
  const segments = h.evidence.events.filter(e => e.type === 'transcript' && e.payload?.speaker === 'assistant' && e.payload.segment_id);
  if (segments.length) {
    const draftSegment = segments.filter(e => e.observed_at_ms < since).at(-1)?.payload.segment_id;
    const savedSegments = segments.filter(e => e.observed_at_ms >= since).map(e => e.payload.segment_id);
    assert(savedSegments.some(id => id !== draftSegment), 'Saved announcement reused the draft caption segment');
    h.evidence.checkpoints.push({kind:'caption-boundaries', draft_segment:draftSegment, saved_segments:[...new Set(savedSegments)], rows});
  } else {
    // Check structure and exact text, independently of the model's save wording
    // or whether a draft pause happened to increase the row count first.
    assertUnsegmentedCaptionRows(rows, assistantText(h.evidence, 0));
  }
  h.evidence.checkpoints.push({kind:'confirmation-caption-rows',rows});
});
define('21-reconnect', 'Reconnect without replaying work; retain a pending draft and answer a fresh read', 'recovery', async h => {
  await h.page.locator('#order-124 input').fill('Pending across reconnect');
  await h.page.locator('#order-124 button').click();
  const pending = await h.draft(/^Pending across reconnect$/);
  const before = await h.dashboard();
  await connect(h, {items:'status124'}); await h.play('items');
  const first = await answer(h,'124','status',/out for delivery/i);
  assert.equal(jobs(first).length,1);
  const previous = h.sessionId();
  await h.disconnect();
  h.evidence.checkpoints.push({kind:'reconnect-start',at_ms:Date.now()});
  await connect(h,{items:'items124'});
  assert.notEqual(h.sessionId(),previous);
  assert.equal(jobs(await h.state()).length,0,'Reconnection replayed old work');
  await h.play('items');
  const second = await answer(h,'124','items',/desk lamp/i);
  assert.equal(jobs(second).length,1,'Fresh read duplicated work');
  const after = await h.dashboard();
  assert.deepEqual(after.orders,before.orders,'Reconnect changed saved orders');
  assert(after.proposals.some(p=>p.id===pending.id && p.status==='pending' && p.instructions===pending.instructions), 'Pending draft lost or changed');
});
define('22-browser-save-announcement', 'Announce an independently browser-created and confirmed draft', 'write-boundary', async h => {
  await connect(h, {items:'status124'});
  const before = await h.dashboard();
  await h.page.locator('#order-124 input').fill('Leave the package at reception');
  await h.page.locator('#order-124 button').click();
  const draft = await h.draft(/^Leave the package at reception$/);
  const since = Date.now();
  h.evidence.checkpoints.push({kind:'browser-confirmation',at_ms:since});
  await h.action(draft.id,'confirm');
  const after = await h.dashboard();
  assert.equal(order(after).version,order(before).version+1);
  assert.equal(order(after).instructions,draft.instructions);
  await expectReply(h, {since, pattern:'saved-reception', target:'124', label:'announce browser-originated saved reception instructions'});
  assert.deepEqual((await h.dashboard()).orders,after.orders);
});
define('24-human-read-correction', 'Deduplicate an equivalent correction, then apply No 123 to the completed status read', 'correction', async h => {
  await connect(h, {items:'status124', interrupt:'sameCorrection', correct:'shortCorrection'});
  await h.play('items'); await answer(h,'124','status',/out for delivery/i);
  await h.play('interrupt'); await h.pause(4500);
  assert.equal(jobs(await h.state()).length,1,'Equivalent correction repeated a lookup');
  await h.play('correct');
  const s = await answer(h,'123','status',/shipped|Friday/i,2);
  assert.equal(jobs(s).length,2,'Correction caused duplicate work');
});
define('25-human-draft-recovery', 'After a read, clarify missing delivery wording and create a neighbor draft without saving', 'recovery', async h => {
  const before = await h.dashboard();
  await connect(h, {items:'instructions', interrupt:'changeWithoutWording', correct:'humanNeighbor'});
  await h.play('items'); await answer(h,'124','instructions',/(?:no|not|none|empty|haven.t)[^.!?]{0,90}(?:instructions|saved|set)|instructions[^.!?]{0,90}(?:none|empty|not|no)/i);
  await h.play('interrupt');
  const since = h.evidence.checkpoints.filter(c => c.kind === 'input-start').at(-1).at_ms;
  await expectReply(h, {since, pattern:/what|which|tell me|provide|specify|say/i, target:'124', label:'ask for missing delivery wording'});
  const partial = await h.dashboard();
  assert.equal(partial.proposals.length,0,'Missing wording created a draft');
  assert.equal(jobs(await h.state()).length,1,'Missing wording started work');
  const question = outputText(h);
  assert(!/ready.{0,35}confirm|confirm.{0,35}(?:on the|in the) (?:page|browser)|update is (?:running|processing)/i.test(question),'Claimed a nonexistent draft was ready');
  await h.play('correct');
  const draft = await h.draft(/^(?:leave|live) with my neighbor[.!]?$/i);
  const delivered = await h.accepted('124','delivery',2);
  await expectReply(h, {since:resultBoundary(h.evidence,delivered,'124','delivery'), pattern:'browser-confirmation', target:'124', label:'announce real neighbor draft for browser review'});
  assert.equal(draft.order,'124');
  assert.deepEqual((await h.dashboard()).orders,before.orders,'Voice changed saved orders');
});
define('26-completed-correction-once', 'Correct a completed read and fetch instructions without repeating either answer', 'correction', async h => {
  await connect(h, {items:'status123', interrupt:'correction', correct:'instructions'});
  await h.play('items'); await answer(h,'123','status',/shipped|Friday/i);
  await h.wait(async () => (await h.state()).status.provider_speech !== 'speaking', 'first speech finishes');
  await h.pause(1000);
  await h.play('interrupt');
  const corrected = await answer(h,'124','status',/out for delivery/i,2);
  const since = resultBoundary(h.evidence,corrected,'124','status');
  await h.pause(6500);
  assert.equal((assistantText(h.evidence,since).match(/out for delivery/gi)||[]).length,1,'Corrected status repeated');
  await h.play('correct');
  const instructions = await answer(h,'124','instructions',/(?:no|not|none|empty|haven.t)[^.!?]{0,90}(?:instructions|saved|set)|instructions[^.!?]{0,90}(?:none|empty|not|no)/i,3);
  await h.pause(6500);
  const inputAt = h.evidence.checkpoints.filter(c=>c.kind==='input-start').at(-1).at_ms;
  const rows = new Map();
  for (const e of h.evidence.events.filter(e=>e.type==='transcript' && e.payload?.speaker==='assistant' && e.observed_at_ms>=inputAt)) {
    const key=e.payload.segment_id || 'unknown'; rows.set(key,(rows.get(key)||'')+e.payload.delta);
  }
  const factual = [...rows.values()].filter(t=>/instructions/i.test(t) && /\b(?:no|not|none|empty|haven.t)\b/i.test(t));
  assert.equal(factual.length,1,'Instructions answer repeated or absent');
  assert.equal(jobs(instructions).length,3,'Duplicated backend work');
  h.evidence.checkpoints.push({kind:'single-answer-check',at_ms:Date.now(),instructions_rows:[...rows.values()]});
});
define('27-front-door-save-once', 'Confirm literal front-door instructions during speech and announce the save once', 'write-boundary', async h => {
  await connect(h, {items:'status124'});
  await h.wait(async () => (await h.state()).status.provider_speech === 'idle', 'greeting speech finishes');
  await h.pause(1000);
  const before=await h.dashboard();
  await h.page.locator('#order-124 input').fill('left in my front door');
  await h.page.locator('#order-124 button').click();
  const draft=await h.draft(/^left in my front door$/);
  await h.play('items');
  await h.wait(async ()=>(await h.state()).status.provider_speech==='speaking','assistant starts status speech');
  const beforeSave=await h.state();
  const observationBoundary=beforeSave.status.observed_at_us;
  const since=Date.now();
  h.evidence.checkpoints.push({kind:'browser-confirmation-during-speech',at_ms:since,state:beforeSave});
  await h.action(draft.id,'confirm');
  await expectReply(h,{since,pattern:/sav(?:ed|ing)|updated/i,target:'124',label:'announce saved front-door instruction'});
  await h.pause(8000);
  const text=assistantText(h.evidence,since);
  assert.equal((text.match(/\b(?:saved|updated)\b/gi)||[]).length,1,'Save announcement repeated');
  assert(/front door/i.test(text),'Save announcement omitted destination');
  const after=await h.dashboard();
  assert.equal(order(after).version,order(before).version+1);
  assert.equal(order(after).instructions,'left in my front door');
  const final=await h.state();
  const interruptions=final.events.filter(e=>e.type==='output_interrupted' && e.observed_at_us>=observationBoundary);
  assert.equal(interruptions.length,0,'Application announcement interrupted speech');
  h.evidence.checkpoints.push({kind:'save-once-check',at_ms:Date.now(),text,interruptions});
});
module.exports = {definitions, phrases, outputText, assertReplyOrder, greetingOutputDrained};
