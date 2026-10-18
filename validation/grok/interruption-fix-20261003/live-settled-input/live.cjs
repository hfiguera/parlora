'use strict';
const {resultDelivered} = require('./delivery.cjs');
const assert = require('node:assert/strict');
const {assertSessionOpen} = require('./assertions.cjs');
const fs = require('node:fs/promises');
const path = require('node:path');
const {promisify} = require('node:util');
const execFile = promisify(require('node:child_process').execFile);
const {chromium} = require('../browser/node_modules/playwright');
let activeBrowser;
async function closeLive() { if (activeBrowser) {const b = activeBrowser; activeBrowser = null; await b.close();} }
const phrases = {
  status123: 'Check order one hundred twenty three.',
  status124: 'Check order one hundred twenty four.',
  correction124: 'Actually, I meant one hundred twenty four.',
  back123: 'No, sorry, go back to one hundred twenty three.',
  missing: 'Can you check my order?',
  number: 'One two four.',
  items: 'What items are in that order?',
  items123: 'What items are in order one hundred twenty three?',
  items124: 'What items are in order one hundred twenty four?',
  draft: 'For order one hundred twenty four, change the delivery instructions to leave it at reception.',
  refuse: "No, don't save that. Keep the original instructions.",
  reception: 'For order one hundred twenty four, leave the package at reception.',
  neighbor: 'Actually, leave it with the neighbor.',
  interrupt: 'Wait! What items are in order one hundred twenty four?'
};
async function prepareAudio(output, inputs = phrases) {
  await fs.mkdir(path.join(output, 'audio'));
  for (const [name, text] of Object.entries(inputs)) await execFile('/usr/bin/say', [
    '-v', 'Samantha', '-r', '165', '--file-format=WAVE', '--data-format=LEI16@24000',
    '-o', path.join(output, 'audio', `${name}.wav`), text
  ], {timeout: 20000});
}
const pause = ms => new Promise(r => setTimeout(r, ms));
async function until(fn, label, deadline) {
  while (Date.now() < deadline) {
    const value = await fn(); if (value) return value;
    await pause(100);
  }
  throw new Error(`Timed out: ${label}`);
}
async function json(url) {
  const response = await fetch(url, {signal: AbortSignal.timeout(3000)});
  assert.equal(response.status, 200); return response.json();
}
async function runLive(url, output, options = {}) {
  await until(async () => {try {return (await json(url + '/health')).active_sessions === 0;} catch (_) {return false;}}, 'isolated server ready', Date.now() + 30000);
  const browser = activeBrowser = await chromium.launch({channel: process.env.BROWSER_CHANNEL || 'chrome', headless: true});
  const results = [];
  try {
    for (const [name, steps] of (options.scenarios || scenarios)) {
      const started = Date.now(), deadline = started + (options.caseTimeoutMs || 150000);
      const context = await browser.newContext();
      const page = await context.newPage();
      page.setDefaultTimeout(15000);
      const evidence = {name, events: [], checkpoints: []};
      let mapping = {}, currentId;
      const seen = new Set();
      page.on('pageerror', error => evidence.events.push({type: 'pageerror', message: error.message}));
      page.on('websocket', socket => socket.on('framereceived', ({payload}) => {
        try {
          const message = JSON.parse(payload.toString());
          // Never record SDP, ICE credentials/candidates, headers, or raw audio.
          if (['transcript', 'event', 'status', 'closed'].includes(message.type) && evidence.events.length < 3000)
            evidence.events.push({...message, observed_at_ms: Date.now()});
        } catch (_) {}
      }));
      await page.route('**/dev/audio/*.wav', async route => {
        const slot = path.basename(new URL(route.request().url()).pathname, '.wav');
        await route.fulfill({contentType: 'audio/wav', path: path.join(output, 'audio', `${mapping[slot] || 'status123'}.wav`)});
      });
      const harness = {
        page, evidence,
        sessionId() {return currentId;},
        async media() {
          if(!options.captureMedia) return undefined;
          return page.evaluate(async()=> (await window.parloraBrowserStats?.() || []).map(row=>Object.fromEntries(Object.entries(row).filter(([k,v])=>k === "type" || (typeof v === "number" && Number.isFinite(v))))));
        },
        async pause(ms) { await pause(ms); },
        async dashboard() {
          const response = await context.request.get(url + '/api/orders');
          assert.equal(response.status(), 200);
          const {csrf, interpretation, ...data} = await response.json(); return data;
        },
        async state(allowClosed = false) {
          const all = await json(url + '/__acceptance/state');
          const state = currentId ? all[currentId] : null;
          if (!allowClosed) assertSessionOpen(state, evidence.events);
          return state;
        },
        async wait(fn, label) {return until(fn, label, deadline);},
        async connect(clips) {
          mapping = clips;
          await page.locator('#recorded-connect').click();
          await until(async () => /Ready/.test(await page.locator('#connection').textContent()), 'call readiness', deadline);
          const entry = await until(async () => {
            const all = await json(url + '/__acceptance/state');
            return Object.entries(all).find(([id, e]) => !seen.has(id) && !e.closed);
          }, 'new session observed', deadline);
          currentId = entry[0]; seen.add(currentId);
          evidence.checkpoints.push({kind: 'connected', at_ms: Date.now(), session_id: currentId, clips, state: entry[1]});
          return entry[1];
        },
        async play(slot) {
          evidence.checkpoints.push({kind: 'input-start', slot, clip: mapping[slot], at_ms: Date.now(), media: await harness.media()});
          await page.locator(`#recorded-${slot}`).click();
          await until(async () => (await page.locator('#recorded-state').textContent()).startsWith(`${slot} clip finished`), `clip ${slot} completion`, deadline);
          evidence.checkpoints.push({kind: 'input-end', slot, clip: mapping[slot], at_ms: Date.now(), media: await harness.media()});
        },
        async captions() {return page.locator('#transcript').innerText();},
        async accepted(order, operation, minimumJobs = 1) {
          return until(async () => {
            const state = await harness.state();
            if (!state || state.status.interpretation !== 'settled') return false;
            const jobs = state.status.jobs;
            if (Object.keys(jobs).length < minimumJobs) return false;
            if (!Object.values(state.status.delegations).every(d => ['claimed','cancelled'].includes(d.status))) return false;
            const match = Object.entries(jobs).find(([id, j]) => j['current?'] && resultDelivered(state, j) &&
              state.jobs[id]?.input.order === order && state.jobs[id]?.input.operation === operation);
            return match ? state : false;
          }, `accepted ${operation} ${order} with settled interpretation`, deadline);
        },
        async submitted(order, operation) {
          return until(async () => {
            const s = await harness.state();
            return s && Object.values(s.jobs).some(j => j.input.order === order && j.input.operation === operation) && s;
          }, `submitted ${operation} ${order}`, deadline);
        },
        async caption(pattern) {return until(async () => pattern.test(await harness.captions()), `caption ${pattern}`, deadline);},
        async draft(pattern) {
          return until(async () => (await harness.dashboard()).proposals.find(p => p.order === '124' && p.status === 'pending' && pattern.test(p.instructions)), 'matching pending draft', deadline);
        },
        async action(id, action) {
          await page.locator(`[data-proposal="${id}"] button[data-action="${action}"]`).click();
          return until(async () => (await harness.dashboard()).proposals.find(p => p.id === id && p.status === (action === 'confirm' ? 'applied' : 'rejected')), `draft ${action}`, deadline);
        },
        async disconnect() {
          if (await page.locator('#disconnect').isEnabled()) await page.locator('#disconnect').click();
          await until(async () => (await json(url + '/health')).active_sessions === 0, 'session cleanup', Date.now() + 12000);
        },
        async checkpoint(kind) {
          const record = {kind, at_ms: Date.now(), media: await harness.media(), session_id: currentId, state: await harness.state(true), dashboard: await harness.dashboard(), captions: await harness.captions()};
          evidence.checkpoints.push(record); return record;
        }
      };
      let error;
      try {
        if (options.beforeCase) await options.beforeCase(url, name);
        await page.goto(url);
        await page.locator('#order-124').waitFor();
        await page.locator('#recorded-input > summary').click();
        await page.locator('#diagnostics > summary').click();
        if (options.baseline) await harness.checkpoint('baseline');
        await steps(harness);
        await harness.checkpoint('completed');
        if (options.validateCase) await options.validateCase(harness, name);
        else if (!name.startsWith('2-')) assert(!evidence.events.some(e => e.event === 'clarification_requested'), 'Unexpected application clarification');
        assert.equal(evidence.events.filter(e => e.type === 'pageerror').length, 0, 'Browser errors');
      } catch (e) {error = e.message;}
      finally {
        try {await harness.checkpoint('final');} catch (_) {}
        if (options.captureCase) {try {await options.captureCase(harness, url, name);} catch (e) {error ||= e.message;}}
        try {await harness.disconnect();} catch (e) {error ||= e.message;}
        if (options.afterCase) {try {await options.afterCase(harness,url,name);} catch (e) {error ||= e.message;}}
        try {await page.screenshot({path: path.join(output, `${name}.png`), fullPage: true});} catch (_) {}
        await context.close();
      }
      const result = {name, status: error ? 'failed' : 'passed', duration_ms: Date.now() - started, error,
        evidence: `${name}.json`};
      results.push(result);
      await fs.writeFile(path.join(output, result.evidence), JSON.stringify(evidence, null, 2));
      await fs.writeFile(path.join(output, 'live.json'), JSON.stringify({mode: 'live', cases: results}, null, 2));
      console.log(`${result.status}: ${name}${error ? ` — ${error}` : ''}`);
    }
  } finally {await closeLive();}
  return {mode: 'live', cases: results, browser:{version:browser.version(),channel:process.env.BROWSER_CHANNEL || 'chrome'}};
}
const order = (dashboard, id = '124') => dashboard.orders.find(o => o.id === id);
const scenarios = [
  ['1-corrections', async h => {
    await h.connect({items: 'status123', interrupt: 'correction124', correct: 'back123'});
    await h.play('items'); await h.submitted('123', 'status');
    await h.play('interrupt'); await h.submitted('124', 'status');
    await h.play('correct'); const state = await h.accepted('123', 'status', 3);
    assert.equal(Object.keys(state.jobs).length, 3, 'Repeated correction created extra jobs');
    assert(Object.values(state.jobs).every(j => ['123', '124'].includes(j.input.order)), 'Unexpected intermediate order lookup');
    await h.caption(/shipped|Friday/i);
  }],
  ['2-missing-number', async h => {
    await h.connect({items: 'missing', interrupt: 'number'});
    await h.play('items'); await h.caption(/order number|three.digit|number.*order/i);
    assert.equal(Object.keys((await h.state()).jobs).length, 0, 'Lookup before number supplied');
    await h.play('interrupt'); await h.accepted('124', 'status'); await h.caption(/out for delivery/i);
  }],
  ['3-different-questions', async h => {
    await h.connect({items: 'status124', interrupt: 'items'});
    await h.play('items'); await h.accepted('124', 'status'); await h.caption(/out for delivery/i);
    await h.play('interrupt'); await h.accepted('124', 'items', 2); await h.caption(/(?:one|1|a) desk lamp/i);
  }],
  ['4-draft-refusal', async h => {
    const before = order(await h.dashboard());
    await h.connect({draft: 'draft', refuse: 'refuse'});
    await h.play('draft'); const draft = await h.draft(/^leave it at reception[.!]?$/i);
    await h.play('refuse');
    await h.wait(async () => (await h.dashboard()).proposals.find(p => p.id === draft.id && p.status === 'rejected'), 'spoken refusal rejected exact draft');
    await h.accepted('124', 'refuse', 2);
    assert.deepEqual(order(await h.dashboard()), before, 'Spoken refusal changed saved order');
  }],
  ['5-draft-correction', async h => {
    const before = order(await h.dashboard());
    await h.connect({package: 'reception', correct: 'neighbor'});
    await h.play('package'); const first = await h.draft(/^leave the package at reception[.!]?$/i);
    await h.play('correct'); const second = await h.draft(/^leave it with the neighbor[.!]?$/i);
    await h.accepted('124', 'delivery', 2);
    assert.notEqual(first.id, second.id);
    assert.deepEqual(order(await h.dashboard()), before, 'Voice saved a draft without browser confirmation');
    await h.action(first.id, 'reject'); await h.action(second.id, 'confirm');
    const after = order(await h.dashboard());
    assert.equal(after.version, before.version + 1); assert.equal(after.instructions, second.instructions);
  }],
  ['6-interrupt-disconnect', async h => {
    // Explicit browser setup ensures this case is independent of case 5 passing.
    await h.page.locator('#order-124 input').fill('Saved before reconnect');
    await h.page.locator('#order-124 button').click();
    const saved = await h.draft(/^Saved before reconnect$/); await h.action(saved.id, 'confirm');
    await h.page.locator('#order-123 input').fill('Pending across reconnect');
    await h.page.locator('#order-123 button').click();
    const pending = await h.wait(async () => (await h.dashboard()).proposals.find(p => p.order === '123' && p.status === 'pending'), 'pending setup draft');
    const before = order(await h.dashboard());
    await h.connect({items: 'items123', interrupt: 'interrupt'});
    await h.play('items');
    await h.wait(async () => (await h.captions()).lastIndexOf('Assistant') > (await h.captions()).lastIndexOf('You') && await h.page.locator('#speaker').evaluate(a => !a.paused), 'assistant speaking before interruption');
    await h.checkpoint('interruption-start');
    await h.play('interrupt');
    const running = await h.wait(async () => {
      const state = await h.state();
      return Object.entries(state.status.jobs).some(([id, j]) => j.status === 'submitted' && j.started_at_us != null && state.jobs[id]?.input.order === '124' && state.jobs[id]?.input.operation === 'items') && state;
    }, 'verified running corrected items job');
    const oldId = running.status.session_id;
    await h.checkpoint('disconnect-running'); await h.disconnect();
    const fresh = await h.connect({items: 'items124'});
    assert.notEqual(fresh.status.session_id, oldId);
    assert.deepEqual(fresh.jobs, {}); assert.deepEqual(fresh.status.delegations, {});
    const caption = await h.captions(); assert(!/What items are in order/i.test(caption), 'Prior-call captions survived reconnect');
    const after = await h.dashboard(); assert.deepEqual(order(after), before);
    assert(after.proposals.some(p => p.id === pending.id && p.status === 'pending'));
    await h.play('items'); await h.accepted('124', 'items'); await h.caption(/(?:one|1|a) desk lamp/i);
  }]
];
module.exports = {runLive, prepareAudio, closeLive, scenarios};
