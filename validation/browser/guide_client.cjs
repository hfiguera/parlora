'use strict';
// Run against a dedicated PARLORA_BROWSER_OFFLINE=1 OrderDesk listener.
// The copied guide HTML uses the real signaling handler, native Opus, and WebRTC.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require('playwright');
if (process.env.PARLORA_BROWSER_OFFLINE !== '1') {
  throw new Error('Start an offline consumer and set PARLORA_BROWSER_OFFLINE=1 for this check.');
}
const url = process.env.BROWSER_URL || 'http://localhost:4000';
const guide = fs.readFileSync(path.join(__dirname, '../../docs/browser-channel.md'), 'utf8');
const html = guide.match(/<!-- browser-client.html -->\s*```html\n([\s\S]*?)\n```/)[1];
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(check, timeout = 10000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) { if (await check()) return; await sleep(100); }
  throw new Error('Timed out waiting for the guide client or session cleanup');
}
async function sessions() { return (await (await fetch(`${url}/health`)).json()).active_sessions; }
(async () => {
  await until(async () => { try { return await sessions() === 0; } catch (_) { return false; } }, 60000);
  const browser = await chromium.launch({channel: process.env.BROWSER_CHANNEL || undefined,
    headless: true, args: ['--use-fake-device-for-media-stream']});
  const report = {client: 'exact docs/browser-channel.md HTML', cycles: []};
  try {
    const context = await browser.newContext({permissions: ['microphone']});
    const page = await context.newPage();
    const incoming = [], outgoing = [], errors = [];
    page.on('pageerror', error => errors.push(error.message));
    page.on('websocket', socket => {
      socket.on('framereceived', ({payload}) => incoming.push(JSON.parse(payload)));
      socket.on('framesent', ({payload}) => outgoing.push(JSON.parse(payload)));
    });
    // Keep the host's real origin/network address space and authentication cookie.
    await page.goto(`${url}/health`); await page.setContent(html);
    for (let cycle = 0; cycle < 2; cycle++) {
      incoming.length = 0; outgoing.length = 0;
      await page.click('#connect');
      await page.waitForFunction(() => document.querySelector('#status').textContent === 'Ready. You can speak.');
      await until(async () => page.evaluate(async () => {
        const stats = [...(await current.peer.getStats()).values()];
        return stats.some(row => row.type === 'inbound-rtp' && row.packetsReceived > 20 && row.totalAudioEnergy > 0)
          && stats.some(row => row.type === 'outbound-rtp' && row.packetsSent > 20);
      }));
      await until(() => outgoing.some(message => message.type === 'ping'));
      assert.equal(await sessions(), 1);
      assert(incoming.findIndex(m => m.type === 'attached') < incoming.findIndex(m => m.type === 'ready'));
      const offer = outgoing.findIndex(m => m.type === 'offer');
      const candidates = outgoing.flatMap((m, i) => m.type === 'candidate' ? [i] : []);
      assert(offer >= 0 && candidates.length > 0 && candidates.every(i => i > offer));
      for (const i of candidates) assert.equal(outgoing[i].candidate.sdpMLineIndex, 0);
      const media = await page.evaluate(async () => {
        const stats = [...(await current.peer.getStats()).values()];
        const received = stats.find(row => row.type === 'inbound-rtp');
        const sent = stats.find(row => row.type === 'outbound-rtp');
        return {received: received.packetsReceived, sent: sent.packetsSent,
          energy: received.totalAudioEnergy, microphone_enabled: current.microphone.getAudioTracks()[0].enabled,
          playing: !document.querySelector('#speaker').paused};
      });
      assert.equal(media.microphone_enabled, true); assert.equal(media.playing, true);
      if (cycle === 0) {
        await page.evaluate(() => { window.savedTracks = current.microphone.getTracks(); });
        await page.click('#disconnect');
        assert.equal(await page.evaluate(() => current === null && savedTracks.every(t => t.readyState === 'ended')), true);
        assert.equal(await page.locator('#connect').isEnabled(), true);
      } else {
        await page.close(); // pagehide must release the owner/session too.
      }
      await until(async () => await sessions() === 0);
      assert.deepEqual(errors, []);
      report.cycles.push({...media, cleanup: cycle === 0 ? 'disconnect' : 'pagehide', status: 'passed'});
    }
    await context.close();
    console.log(JSON.stringify(report));
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
