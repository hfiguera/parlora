'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

function harness(options = {}) {
  const elements = new Map(), contexts = [];
  const el = id => {
    if (!elements.has(id)) elements.set(id, {disabled: false, textContent: ''});
    return elements.get(id);
  };
  class AudioContext {
    constructor() { this.nodes = []; this.closed = false; contexts.push(this); }
    resume() { return options.resume?.() || Promise.resolve(); }
    close() { this.closed = true; return Promise.resolve(); }
    decodeAudioData() { return Promise.resolve({duration: options.duration || 5}); }
    createMediaStreamDestination() {
      this.track = {readyState: 'live', stop() { this.readyState = 'ended'; }};
      return {stream: {getTracks: () => [this.track]}};
    }
    node() {
      const node = {offset: {}, started: false, stopped: false, disconnected: false,
        connect() {}, start() { this.started = true; },
        stop() { if (!this.started) throw new Error('not started'); this.stopped = true; },
        disconnect() { this.disconnected = true; }};
      this.nodes.push(node); return node;
    }
    createConstantSource() { return this.node(); }
    createBufferSource() { return this.node(); }
  }
  const scope = {window: {}, document: {getElementById: el}, AudioContext, AbortController, AbortSignal,
    fetch: async () => ({ok: true, arrayBuffer: async () => new ArrayBuffer(4)})};
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../../examples/order_desk/priv/browser/recorded-input.js'), 'utf8'), scope);
  return {input: scope.window.OrderDeskRecordedInput, el, contexts};
}

test('recorded input serializes clips; mute and disconnect stop sources and release tracks/context', async () => {
  const {input, el, contexts} = harness();
  await input.open();
  assert.equal(el('recorded-draft').disabled, true);
  input.update(true, true, true, false);
  assert.equal(el('recorded-state').textContent, 'Ready for a recorded clip.');
  const first = el('recorded-draft').onclick();
  const second = el('recorded-refuse').onclick();
  await Promise.all([first, second]);
  assert.equal(contexts[0].nodes.length, 2); // one silence source, one clip
  assert.equal(el('recorded-refuse').disabled, true);
  input.update(true, true, true, true);
  assert.equal(contexts[0].nodes[1].stopped, true);
  assert.equal(el('recorded-draft').disabled, true);
  input.close();
  assert.equal(contexts[0].nodes[0].stopped, true);
  assert.equal(contexts[0].track.readyState, 'ended');
  assert.equal(contexts[0].closed, true);
  assert.equal(el('recorded-connect').disabled, false);
  await input.open();
  assert.equal(contexts.length, 2);
  input.close();
  assert.equal(contexts[1].closed, true);
});

test('disconnect during AudioContext resume cannot start a canceled clip', async () => {
  let blocked = false, release;
  const {input, el, contexts} = harness({resume: () => blocked ? new Promise(resolve => { release = resolve; }) : Promise.resolve()});
  await input.open();
  input.update(true, true, true, false);
  blocked = true;
  const playback = el('recorded-draft').onclick();
  input.close();
  release(); await playback;
  assert.equal(contexts[0].nodes[1].started, false);
  assert.equal(contexts[0].nodes[1].disconnected, true);
  assert.equal(contexts[0].closed, true);
});

test('oversized duration rejects the input and closes its AudioContext', async () => {
  const {input, el, contexts} = harness({duration: 21});
  await assert.rejects(input.open(), /20-second limit/);
  assert.equal(contexts[0].closed, true);
  assert.equal(el('recorded-connect').disabled, false);
});
