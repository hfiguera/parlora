'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

test('delay notice keeps the call open and accepts a later reply', async () => {
  const source = fs.readFileSync(path.join(__dirname, '../../examples/order_desk/priv/browser/voice.js'), 'utf8');
  const notices = [], captions = [], closes = [];
  const scope = {pc: {}, status: text => notices.push(text), caption: text => captions.push(text),
    note() {}, cleanup: text => closes.push(text)};
  const callback = source.slice(source.indexOf('const receive ='), source.indexOf('const selectedPath ='));
  vm.runInNewContext(callback + '; this.deliver = receive;', scope);
  await scope.deliver({type: 'event', event: 'response_status', payload: {status: 'delayed'}});
  assert.match(notices.at(-1), /taking longer/);
  assert.equal(closes.length, 0);
  await scope.deliver({type: 'event', event: 'response_status', payload: {status: 'progress_observed'}});
  await scope.deliver({type: 'transcript', payload: {speaker: 'assistant', delta: 'Goodbye!'}});
  assert.equal(notices.at(-1), 'Connected');
  assert.equal(captions[0].delta, 'Goodbye!');
  assert.equal(closes.length, 0);
  await scope.deliver({type: 'event', event: 'failed', payload: {cause: 'progress_timeout'}});
  assert.equal(closes.length, 1);
});
