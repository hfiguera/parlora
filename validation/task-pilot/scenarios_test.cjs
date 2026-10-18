'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {definitions,phrases,outputText,assertReplyOrder,greetingOutputDrained} = require('./scenarios.cjs');
test('ordinary input waits for generated greeting audio to drain, not just its caption',()=>{
  const state = {status:{provider_speech:'idle',observed_at_us:-1_000_000,
    health:{output_forwarded:{frames:193,last_at_us:-1_100_000}}}};
  assert.equal(greetingOutputDrained(state),false);
  state.status.observed_at_us = -600_001;
  assert.equal(greetingOutputDrained(state),false);
  state.status.observed_at_us = -600_000;
  assert.equal(greetingOutputDrained(state),true);
  state.status.provider_speech = 'speaking';
  assert.equal(greetingOutputDrained(state),false);
});
test('absent or unstarted audio cannot satisfy greeting drain',()=>{
  assert.equal(greetingOutputDrained(null),false);
  assert.equal(greetingOutputDrained({status:{provider_speech:'idle'}}),false);
  assert.equal(greetingOutputDrained({status:{provider_speech:'idle',observed_at_us:1_000_000,
    health:{output_forwarded:{frames:0,last_at_us:0}}}}),false);
});
test('pilot has twenty-seven distinct expected outcomes and explicit fixture phrases',()=>{
  assert.equal(definitions.length,27);
  assert.equal(new Set(definitions.map(d=>d.id)).size,27);
  assert(definitions.every(d=>d.goal && typeof d.run==='function'));
  assert(phrases.paused.includes('[[slnc 350]]'));
});
test('a correct item fact cannot excuse naming another order in its reply',()=>{
  assertReplyOrder([], '124'); // The provider need not repeat the ID.
  assertReplyOrder(['124'], '124');
  assert.throws(()=>assertReplyOrder(['123'],'124'),/different order/);
  assert.throws(()=>assertReplyOrder(['123','124'],'124'),/different order/);
});
test('caller text and an earlier reply cannot satisfy the latest answer assertion',()=>{
  const h={evidence:{checkpoints:[{kind:'input-start',at_ms:100},{kind:'input-start',at_ms:300}],events:[
    {type:'transcript',observed_at_ms:200,payload:{speaker:'assistant',delta:'shipped'}},
    {type:'transcript',observed_at_ms:310,payload:{speaker:'user',delta:'out for delivery'}},
    {type:'transcript',observed_at_ms:320,payload:{speaker:'assistant',delta:'checking '}}]}};
  assert.equal(outputText(h),'checking ');
  h.evidence.events.push({type:'transcript',observed_at_ms:350,payload:{speaker:'assistant',delta:'out for delivery'}});
  assert.equal(outputText(h),'checking out for delivery');
});
