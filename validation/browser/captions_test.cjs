'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

function harness() {
  function node() {
    return {children: [], dataset: {}, textContent: '', scrollHeight: 0, scrollTop: 0, clientHeight: 0,
      append(...children) { children.forEach(child => { child.parent = this; this.children.push(child); }); },
      remove() { this.parent.children.splice(this.parent.children.indexOf(this), 1); },
      replaceWith(child) { child.parent = this.parent; this.parent.children[this.parent.children.indexOf(this)] = child; },
      querySelector() { return null; },
      get firstElementChild() { return this.children[0]; },
      get lastChild() { return this.children.at(-1); }};
  }
  const transcript = node();
  const scope = {el: () => transcript, document: {createElement: node, createTextNode: () => node()}};
  const source = fs.readFileSync(path.join(__dirname, '../../examples/order_desk/priv/browser/voice.js'), 'utf8');
  // Execute the actual rendering callback, without microphone or network mocks.
  const callback = source.slice(source.indexOf('const caption ='), source.indexOf('const receive ='));
  vm.runInNewContext('let captions = [], captionEpoch = 0; ' + callback + '; this.render = caption; this.recover = () => captionEpoch++;', scope);
  return {send: scope.render, recover: scope.recover, rows: () => transcript.children.map(p => p.lastChild.textContent)};
}

test('separate Gemini replies render separately without a caller caption between them', () => {
  const h = harness();
  h.send({speaker: 'assistant', segment_id: 'draft', delta: 'Please confirm to save the change.'});
  h.send({speaker: 'assistant', segment_id: 'saved', delta: 'Order 124 delivery instructions have been updated.'});
  assert.deepEqual(h.rows(), ['Please confirm to save the change.', 'Order 124 delivery instructions have been updated.']);
});

test('split words, numbers, punctuation and corrections remain exact within a segment', () => {
  const h = harness();
  for (const delta of ['Order 1', '24: deliv', 'ery.', ' Actually, 123.'])
    h.send({speaker: 'assistant', segment_id: 'one', delta});
  assert.deepEqual(h.rows(), ['Order 124: delivery. Actually, 123.']);
});

test('providers without segment IDs retain their original fragments without fabricated boundaries', () => {
  const h = harness();
  for (const delta of ['deliv', 'ery', '.']) h.send({speaker: 'assistant', delta});
  h.send({speaker: 'user', delta: 'Thanks.'});
  assert.deepEqual(h.rows(), ['delivery.', 'Thanks.']);
});

test('GPT Live draft and saved announcement use separate rows without a caller caption', () => {
  const h = harness();
  h.send({speaker: 'assistant', delta: 'Please confirm the draft.', start_ms: 1000, end_ms: 3000});
  h.send({speaker: 'assistant', delta: 'Order 124 has been saved.', start_ms: 15000, end_ms: 17000});
  assert.deepEqual(h.rows(), ['Please confirm the draft.', 'Order 124 has been saved.']);
});

test('timed fragments preserve split numbers, words and exact whitespace across small gaps', () => {
  const h = harness();
  h.send({speaker: 'assistant', delta: 'Order 1', start_ms: 0, end_ms: 300});
  h.send({speaker: 'assistant', delta: '24: deliv', start_ms: 1299, end_ms: 1400});
  h.send({speaker: 'assistant', delta: 'ery.  Actually, 123.', start_ms: 1400, end_ms: 1700});
  h.send({speaker: 'assistant', delta: 'New reply.', start_ms: 2700, end_ms: 3000});
  assert.deepEqual(h.rows(), ['Order 124: delivery.  ', 'Actually, 123.', 'New reply.']);
});

test('overlapping speakers grow their own timed rows independently', () => {
  const h = harness();
  h.send({speaker: 'user', delta: 'Order 1', start_ms: 1000, end_ms: 1500});
  h.send({speaker: 'assistant', delta: 'Sure.', start_ms: 1300, end_ms: 1800});
  h.send({speaker: 'user', delta: '24 please.', start_ms: 1500, end_ms: 2300});
  h.send({speaker: 'assistant', delta: ' Checking.', start_ms: 1800, end_ms: 2400});
  assert.deepEqual(h.rows(), ['Order 124 please.', 'Sure. ', 'Checking.']);
});

test('late captions update the earlier interval instead of merging with a newer reply', () => {
  const h = harness();
  h.send({speaker: 'assistant', delta: 'Review the draft.', start_ms: 1000, end_ms: 2000});
  h.send({speaker: 'assistant', delta: 'Saved.', start_ms: 10000, end_ms: 11000});
  h.send({speaker: 'assistant', delta: ' Please confirm.', start_ms: 2100, end_ms: 2800});
  assert.deepEqual(h.rows(), ['Review the draft. ', 'Please confirm.', 'Saved.']);
});

test('a late first fragment is placed before newer timeline groups', () => {
  const h = harness();
  h.send({speaker: 'assistant', delta: 'Saved.', start_ms: 10000, end_ms: 11000});
  h.send({speaker: 'user', delta: 'Please change it.', start_ms: 1000, end_ms: 2000});
  assert.deepEqual(h.rows(), ['Please change it.', 'Saved.']);
});

test('provider segment identity takes precedence over gaps and overlapping speakers', () => {
  const h = harness();
  h.send({speaker: 'assistant', segment_id: 'draft', delta: 'Review', start_ms: 0, end_ms: 1000});
  h.send({speaker: 'user', item_id: 'caller', delta: 'Okay.'});
  h.send({speaker: 'assistant', segment_id: 'draft', delta: ' the draft.', start_ms: 10000, end_ms: 11000});
  h.send({speaker: 'assistant', segment_id: 'saved', delta: 'Saved.', start_ms: 11000, end_ms: 12000});
  assert.deepEqual(h.rows(), ['Review the draft.', 'Okay.', 'Saved.']);
});

test('missing or invalid timing falls back without corrupting timed or identified rows', () => {
  const h = harness();
  h.send({speaker: 'assistant', segment_id: 'known', delta: 'Known reply.'});
  h.send({speaker: 'assistant', delta: 'Untimed', start_ms: null, end_ms: null});
  h.send({speaker: 'assistant', delta: ' fragments.', start_ms: 200, end_ms: 100});
  h.send({speaker: 'assistant', delta: 'Timed.', start_ms: 0, end_ms: 1000});
  assert.deepEqual(h.rows(), ['Known reply.', 'Untimed fragments.', 'Timed.']);
});

test('timed caption history and long text remain bounded', () => {
  const h = harness();
  for (let i = 0; i < 110; i++)
    h.send({speaker: 'assistant', delta: String(i), start_ms: i * 2000, end_ms: i * 2000 + 100});
  assert.equal(h.rows().length, 100);
  assert.equal(h.rows()[0], '10');
  h.send({speaker: 'assistant', delta: 'x'.repeat(12000), start_ms: 220000, end_ms: 221000});
  assert.equal(h.rows().length, 100);
  assert.equal(h.rows().at(-1).length, 10000);
});

test('the manual-call trailing reminder and nearby saved announcement render independently', () => {
  const h = harness();
  h.send({speaker:'assistant',delta:'Please press Confirm to save it.',start_ms:1000,end_ms:10000});
  h.send({speaker:'assistant',delta:"Saying yes won't save it.",start_ms:11800,end_ms:13200});
  h.send({speaker:'assistant',delta:' Just to note, order 124 has saved the instruction: left in my front door.',start_ms:13400,end_ms:17000});
  assert.deepEqual(h.rows(), ['Please press Confirm to save it.', "Saying yes won't save it. ",
    'Just to note, order 124 has saved the instruction: left in my front door.']);
});

test('a single timed delta containing both reminder and save is split without changing text', () => {
  const h = harness();
  const text = "Saying yes won’t save it. Just to note, order 124 has saved the instruction: left in my front door.";
  h.send({speaker:'assistant',delta:text,start_ms:0,end_ms:5000});
  assert.deepEqual(h.rows(), ['Saying yes won’t save it. ', 'Just to note, order 124 has saved the instruction: left in my front door.']);
  assert.equal(h.rows().join(''), text);
});

test('sentence segmentation is independent of delta boundaries and retains quotes and decimal versions', () => {
  const text = 'Review “front door.”  Record version 1.13.0. Saved!';
  for (const fragments of [[text], [...text], ['Review “front door.', '”  Record version 1.', '13.', '0.', ' Saved', '!']]) {
    const h = harness();
    fragments.forEach((delta,i) => h.send({speaker:'assistant',delta,start_ms:i*100,end_ms:(i+1)*100}));
    assert.deepEqual(h.rows(), ['Review “front door.”  ', 'Record version 1.13.0. ', 'Saved!']);
    assert.equal(h.rows().join(''),text);
  }
});

test('native reply IDs retain their multi-sentence replies while timed callers get sentence rows', () => {
  const h = harness();
  const reply = 'One desk lamp. Tracking: DEMO-124.';
  h.send({speaker:'assistant',segment_id:'native',delta:reply,start_ms:0,end_ms:1000});
  h.send({speaker:'user',delta:'Okay. Thank you.',start_ms:200,end_ms:1400});
  assert.deepEqual(h.rows(), [reply,'Okay. ','Thank you.']);
});

test('sentence-expanded display history is also bounded to 100 rows', () => {
  const h = harness();
  h.send({speaker:'assistant',delta:Array.from({length:110},(_,i)=>`Sentence ${i}. `).join(''),start_ms:0,end_ms:20000});
  assert.equal(h.rows().length,100);
  assert.equal(h.rows()[0],'Sentence 10. ');
  assert.equal(h.rows().at(-1),'Sentence 109. ');
});


test('voice transport recovery starts a fresh caption group even when timestamps touch', () => {
  const h = harness();
  h.send({speaker: 'assistant', delta: 'The delivery instruc', start_ms: 1000, end_ms: 1500});
  h.recover();
  h.send({speaker: 'assistant', delta: 'I had an audio problem.', start_ms: 1500, end_ms: 1800});
  assert.deepEqual(h.rows(), ['The delivery instruc', 'I had an audio problem.']);
});
