'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const {chromium} = require('../browser/node_modules/playwright');
const {prepareAudio, scenarios: browserScenarios} = require('../acceptance/live.cjs');
const sdk = require('./sdk.cjs');
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));

async function main(config) {
  await prepareAudio(config.output);
  const browser = await chromium.launch({channel: 'chrome', headless: true,
    args: ['--autoplay-policy=no-user-gesture-required', '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream']});
  const results = [];
  const context = await browser.newContext();
  const review = await context.newPage();
  await review.goto(config.review + '/phone-review');
  try {
    for (const [name, exercise] of (config.controls ? [['7-remote-controls', controls]] : [...browserScenarios.slice(0, 5), ['6-interrupt-disconnect', interrupt]])) {
      const deadline = Date.now() + 120000;
      const evidence = {name, checkpoints: []};
      const seen = new Set();
      let caller, sessionId, mapping;
      const h = {
        page: review,
        async wait(fn, label, timeoutMs = 45000) {
          const waitDeadline = Date.now() + timeoutMs;
          while (Date.now() < Math.min(deadline, waitDeadline)) {const value = await fn(); if (value) return value; await pause(100);}
          throw new Error('Timed out: ' + label);
        },
        async all() {
          const response = await context.request.get(config.review + '/__acceptance/state');
          assert.equal(response.status(), 200); return response.json();
        },
        async state(allowClosed = false) {
          const state = (await h.all())[sessionId];
          assert(state, 'Session observation missing');
          if (!allowClosed) {
            assert(!state.closed && state.status.status === 'ready', 'Call closed unexpectedly');
            assert(!state.events.some(e => e.type === 'failed'), 'Adapter reported a failure');
          }
          return state;
        },
        async connect(clips) {
          mapping = clips;
          for (const id of Object.keys(await h.all())) seen.add(id);
          caller = await sdk.connect(browser, config);
          const entry = await h.wait(async () => Object.entries(await h.all()).find(([id, s]) => !seen.has(id) && !s.closed && s.status.status === 'ready'), 'new ready phone session');
          sessionId = entry[0]; seen.add(sessionId);
          await h.wait(async () => (await h.state()).events.some(e => e.type === 'transcript_delta' && e.payload.speaker === 'assistant'), 'assistant greeting');
          evidence.checkpoints.push({kind: 'connected', session_id: sessionId, state: await h.state()});
          return h.state();
        },
        async play(slot) {await sdk.play(caller, path.join(config.output, 'audio', mapping[slot] + '.wav'));},
        async captions() {return (await h.state()).events.filter(e => e.type === 'transcript_delta' && e.payload.speaker === 'assistant').map(e => e.payload.delta).join('');},
        async caption(pattern) {return h.wait(async () => pattern.test(await h.captions()), 'assistant caption ' + pattern);},
        async submitted(order, operation) {
          return h.wait(async () => {const s = await h.state(); return Object.values(s.jobs).some(j => j.input.order === order && j.input.operation === operation) && s;}, 'job submitted');
        },
        async accepted(order, operation, minimumJobs = 1) {
          return h.wait(async () => {
            const s = await h.state();
            if (s.status.interpretation !== 'settled' || Object.keys(s.jobs).length < minimumJobs || !Object.values(s.status.delegations).every(d => d.status === 'claimed')) return false;
            return Object.entries(s.status.jobs).some(([id, j]) => j['current?'] && j.delivery === 'accepted' && s.jobs[id]?.input.order === order && s.jobs[id]?.input.operation === operation) && s;
          }, 'accepted ' + order + ' ' + operation);
        },
        async dashboard() {
          const response = await context.request.get(config.review + '/api/orders');
          assert.equal(response.status(), 200);
          const {csrf, interpretation, ...data} = await response.json(); return data;
        },
        async draft(pattern) {return h.wait(async () => (await h.dashboard()).proposals.find(p => p.order === '124' && p.status === 'pending' && pattern.test(p.instructions)), 'matching draft');},
        async action(id, action) {
          await review.locator(`[data-proposal="${id}"] button[data-action="${action}"]`).click();
          return h.wait(async () => (await h.dashboard()).proposals.find(p => p.id === id && p.status === (action === 'confirm' ? 'applied' : 'rejected')), 'draft action');
        },
        async checkpoint(kind) {evidence.checkpoints.push({kind, state: await h.state(), audio: await sdk.metrics(caller)});},
        async disconnect() {
          if (!caller) return;
          evidence.checkpoints.push({kind: 'before-hangup', state: await h.state(true), audio: await sdk.metrics(caller)});
          await sdk.disconnect(caller); caller = null;
          await h.wait(async () => (await h.state(true)).closed, 'session cleanup after hangup');
          evidence.checkpoints.push({kind: 'after-hangup', state: await h.state(true)});
        },
        async control(operation) {
          const response = await context.request.post(config.review + '/__acceptance/control', {data: {session_id: sessionId, operation}});
          assert.equal(response.status(), 200);
          return (await response.json()).command_id;
        },
        async audio() {return sdk.metrics(caller);},
        async speaking() {
          const state = await h.state(), audio = await sdk.metrics(caller);
          const last = state.events.filter(e => e.type === 'transcript_delta').at(-1);
          return last?.payload.speaker === 'assistant' && audio.lastEnergyAgeMs !== null && audio.lastEnergyAgeMs < 150;
        }
      };
      let error = null;
      try {
        await exercise(h);
        await pause(1500);
        await h.checkpoint('scenario-complete');
        const audio = await sdk.metrics(caller);
        assert(audio.energySamples > 0 && audio.status === 'open' && audio.errors.length === 0, 'Caller audio missing or closed');
        await h.disconnect();
      } catch (failure) {
        error = String(failure.message).split('\n')[0].replaceAll(config.token, '[redacted]').replaceAll(config.nonce, '[redacted]');
        evidence.failure_state = await h.all().catch(() => ({}));
        if (caller) {evidence.failure_audio = await sdk.metrics(caller).catch(() => null); await sdk.disconnect(caller).catch(() => {}); caller = null;}
      }
      results.push({name, status: error ? 'failed' : 'passed', error});
      await fs.writeFile(path.join(config.output, name + '.json'), JSON.stringify(evidence, null, 2) + '\n');
      await fs.writeFile(config.report, JSON.stringify({channel: config.channel || 'twilio', caller: 'twilio_sdk', cases: results}, null, 2) + '\n');
      console.log(JSON.stringify(results.at(-1)));
      // Preserve and diagnose the first nondeterministic failure before more calls.
      if (error) break;
    }
  } finally {await browser.close();}
}

async function controls(h) {
  await h.connect({items: 'status124'});
  await h.wait(() => h.speaking(), 'greeting audio before clear');
  await h.checkpoint('before-clear');
  const id = await h.control('clear');
  await h.wait(async () => (await h.state()).events.some(e => e.type === 'control_completed' && e.command_id === id), 'remote clear barrier');
  await h.checkpoint('after-clear-barrier');
  assert((await h.state()).playback.unknown > 0, 'Cleared in-flight marks must remain unknown');
  await h.control('suppress');
  await pause(900);
  const audio = await h.audio();
  assert(audio.lastEnergyAgeMs === null || audio.lastEnergyAgeMs > 400, 'Suppressed output still active at caller');
  await h.control('resume');
  await h.play('items');
  await h.accepted('124', 'status'); await h.caption(/out for delivery/i);
}

async function interrupt(h) {
  await h.page.locator('#order-124 input').fill('Saved before reconnect');
  await h.page.locator('#order-124 button').click();
  const saved = await h.draft(/^Saved before reconnect$/); await h.action(saved.id, 'confirm');
  await h.page.locator('#order-123 input').fill('Pending across reconnect');
  await h.page.locator('#order-123 button').click();
  const pending = await h.wait(async () => (await h.dashboard()).proposals.find(p => p.order === '123' && p.status === 'pending'), 'setup draft');
  const before = (await h.dashboard()).orders.find(o => o.id === '124');
  await h.connect({items: 'items123', interrupt: 'interrupt'});
  await h.play('items');
  await h.wait(() => h.speaking(), 'assistant audio before interruption');
  await h.checkpoint('interruption-start'); await h.play('interrupt');
  const running = await h.wait(async () => {
    const s = await h.state();
    return Object.entries(s.status.jobs).some(([id, j]) => j.status === 'submitted' && j.started_at_us != null && s.jobs[id]?.input.order === '124' && s.jobs[id]?.input.operation === 'items') && s;
  }, 'verified running corrected items job');
  await h.checkpoint('disconnect-running'); await h.disconnect();
  const fresh = await h.connect({items: 'items124'});
  assert.notEqual(fresh.status.session_id, running.status.session_id);
  assert.deepEqual(fresh.jobs, {}); assert.deepEqual(fresh.status.delegations, {});
  const after = await h.dashboard(); assert.deepEqual(after.orders.find(o => o.id === '124'), before);
  assert(after.proposals.some(p => p.id === pending.id && p.status === 'pending'));
  await h.play('items'); await h.accepted('124', 'items'); await h.caption(/(?:one|1|a) desk lamp/i);
}

let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => input += chunk);
process.stdin.on('end', () => main(JSON.parse(input)).catch(() => {process.exitCode = 1;}));
