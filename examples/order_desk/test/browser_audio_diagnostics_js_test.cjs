'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../priv/browser/audio-diagnostics.js'), 'utf8');
function harness() {
  const intervals = new Map(); let index = 0;
  const element = () => ({append() {}, setAttribute() {}});
  const context = {window: {}, document: {createElement: element, getElementById: element},
    performance, Date, AbortSignal, setTimeout, clearTimeout,
    setInterval: fn => { intervals.set(++index, fn); return index; },
    clearInterval: id => intervals.delete(id),
    fetch: async url => ({ok: true, json: async () => ({calls: [{session_id: new URL(url, 'http://localhost').searchParams.get('session_id'), closed: true, events_seen: 12, events: []}]})})};
  vm.runInNewContext(source, context);
  return {context, intervals, api: context.window.OrderDeskAudioDiagnostics,
    reports: context.window.parloraAudioDiagnostics};
}
test('final receiver counters survive disconnect, omit identifiers, and match their server session', async () => {
  const h = harness(); let closed = false;
  const peer = {getStats: async () => {
    assert.equal(closed, false);
    return new Map([['inbound', {type: 'inbound-rtp', kind: 'audio', packetsLost: 2,
      concealedSamples: 480, address: 'private-address', ssrc: 123, trackIdentifier: 'private-track'}]]);
  }, close: () => { closed = true; }};
  h.api.start(peer); h.api.bind('call-1');
  await h.api.finish(peer);
  const [report] = h.reports();
  assert.equal(closed, true);
  assert.equal(h.intervals.size, 0);
  assert.equal(report.state, 'finished');
  assert.equal(report.final_stats, true);
  assert.equal(report.server.session_id, 'call-1');
  assert.equal(report.receiver[0].stats[0].concealedSamples, 480);
  assert.equal(report.receiver[0].stats[0].packetsLost, 2);
  assert.equal(JSON.stringify(report).includes('private'), false);
  assert.equal(JSON.stringify(report).includes('ssrc'), false);
});
test('reconnect while the preceding report finishes retains separate sessions', async () => {
  const h = harness(); let release;
  const oldPeer = {getStats: () => new Promise(resolve => { release = resolve; }), close() {}};
  h.api.start(oldPeer); h.api.bind('old'); const finishing = h.api.finish(oldPeer);
  const newPeer = {getStats: async () => new Map(), close() {}};
  h.api.start(newPeer); h.api.bind('new');
  release(new Map()); await finishing; await h.api.finish(newPeer);
  const reports = h.reports();
  assert.deepEqual(Array.from(reports, r => r.server.session_id), ['old', 'new']);
  for (let i = 0; i < 5; i++) { h.api.start(newPeer); h.api.bind(`next-${i}`); await h.api.finish(newPeer); }
  assert.equal(h.reports().length, 4);
});
test('unavailable receiver statistics are explicit and never prevent peer cleanup', async () => {
  const h = harness(); let closed = false;
  const peer = {getStats: async () => { throw new Error('closed'); }, close: () => { closed = true; }};
  h.api.start(peer); await h.api.finish(peer);
  const [report] = h.reports();
  assert.equal(closed, true);
  assert.equal(report.final_stats, false);
  assert.equal(report.stats_failures, 1);
  assert.equal(report.server_error, 'session_not_attached');
});
