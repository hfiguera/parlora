// Offline real-browser checks. Requires the consumer's PARLORA_BROWSER_OFFLINE=1 server.
const assert = require('node:assert/strict');
const {chromium} = require('playwright');
const url = process.env.BROWSER_URL || 'http://localhost:4000';
const expectRelay = process.env.EXPECT_RELAY === '1';
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(check, timeout = 10000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) { if (await check()) return; await sleep(100); }
  throw new Error('Timed out waiting for browser/session state');
}
async function sessions() { return (await (await fetch(`${url}/health`)).json()).active_sessions; }
(async () => {
  await until(async () => { try { await sessions(); return true; } catch (_) { return false; } }, 60000);
  const browser = await chromium.launch({channel: process.env.BROWSER_CHANNEL || undefined,
    args: ['--use-fake-device-for-media-stream'], headless: true});
  const result = {cycles: [], permission_denial: false, origin_rejection: false};
  try {
    const denied = await browser.newContext();
    await denied.grantPermissions([], {origin: url});
    const deniedPage = await denied.newPage();
    const cdp = await denied.newCDPSession(deniedPage);
    await cdp.send('Browser.setPermission', {permission: {name: 'microphone'}, setting: 'denied', origin: url, browserContextId: (await cdp.send('Target.getTargetInfo')).targetInfo.browserContextId});
    await deniedPage.goto(url); await deniedPage.click('#connect');
    await deniedPage.waitForFunction(() => document.querySelector('#connection').textContent.includes('permission denied'));
    assert.equal(await sessions(), 0); result.permission_denial = true; await denied.close();
    const response = await fetch(`${url}/voice`, {headers: {Origin: 'http://untrusted.invalid'}});
    assert.equal(response.status, 403); result.origin_rejection = true;
    const context = await browser.newContext({permissions: ['microphone']});
    for (let cycle = 0; cycle < 3; cycle++) {
      const page = await context.newPage();
      const messages = []; page.on('pageerror', error => { throw error; });
      page.on('websocket', ws => ws.on('framereceived', ({payload}) => { if (messages.length < 1000) messages.push(JSON.parse(payload)); }));
      await page.goto(url); await page.click('#connect');
      await page.waitForFunction(() => document.querySelector('#connection').textContent.startsWith('Ready'));
      await page.locator('#playback-controls > summary').click();
      await page.locator('#diagnostics > summary').click();
      await sleep(1000);
      await page.click('#status'); await until(() => messages.some(m => m.type === 'status'));
      const warm = messages.findLast(m => m.type === 'status').media;
      const warmRtp = (await page.evaluate(() => window.parloraBrowserStats())).find(row => row.type === 'inbound-rtp');
      const statusCount = messages.filter(m => m.type === 'status').length;
      await sleep(3000);
      await page.click('#status');
      await until(() => messages.filter(m => m.type === 'status').length > statusCount);
      const steady = messages.findLast(m => m.type === 'status').media;
      assert(steady.received > warm.received); assert(steady.sent > warm.sent);
      assert(steady.input_bytes <= 19200 && steady.output_bytes <= 10560);
      const stats = await page.evaluate(() => window.parloraBrowserStats());
      const route = await page.evaluate(() => window.parloraConnectionPath());
      assert(route && route.bytes_sent > 0 && route.bytes_received > 0);
      if (expectRelay) { assert.equal(route.local, 'relay'); assert.equal(route.remote, 'relay'); }
      const incoming = stats.find(row => row.type === 'inbound-rtp');
      const outgoing = stats.find(row => row.type === 'outbound-rtp');
      assert(incoming.packetsReceived > 50); assert(incoming.totalAudioEnergy > 0); assert(outgoing.packetsSent > 20);
      await page.click('#mute'); assert.equal(await page.locator('#mute').textContent(), 'Unmute microphone');
      assert.equal(await page.locator('#mute').getAttribute('aria-pressed'), 'true');
      assert.match(await page.locator('#microphone-state').textContent(), /muted/);
      await page.click('#mute');
      for (const action of ['stop', 'clear', 'resume']) {
        await page.click(`#${action}`);
        await until(() => messages.some(m => m.type === 'control' && m.action === action && m.accepted));
      }
      await sleep(50);
      const beforeControlStatus = messages.filter(m => m.type === 'status').length;
      await page.click('#status');
      await until(() => messages.filter(m => m.type === 'status').length > beforeControlStatus);
      assert.equal(messages.findLast(m => m.type === 'status').status.playback.handed_off.epoch, 1);
      const closeStart = Date.now();
      if (cycle === 0) await page.click('#disconnect');
      await page.close(); // abrupt page close also releases the signaling-owned channel/session
      await until(async () => (await sessions()) === 0);
      result.cycles.push({media_path: route, packets_received: incoming.packetsReceived, packets_sent: outgoing.packetsSent,
        packets_lost: incoming.packetsLost, concealed_samples: incoming.concealedSamples,
        warmup_concealed_samples: warmRtp.concealedSamples,
        steady_concealed_samples: incoming.concealedSamples - warmRtp.concealedSamples,
        jitter_seconds: incoming.jitter, max_server_tick_gap_us: steady.max_tick_gap_us,
        steady_playback_silence_bytes: steady.playback_silence_bytes - warm.playback_silence_bytes,
        steady_playback_starvations: steady.playback_starvations - warm.playback_starvations,
        cleanup_ms: Date.now() - closeStart});
    }
    if (expectRelay) {
      const deniedTurn = await context.newPage();
      await deniedTurn.route('**/ice-config', async route => {
        const response = await route.fetch(); const config = await response.json();
        config.iceServers = config.iceServers.map(server => server.username ? {...server, credential: 'invalid-test-credential'} : server);
        await route.fulfill({response, json: config});
      });
      let becameReady = false;
      deniedTurn.on('websocket', ws => ws.on('framereceived', ({payload}) => { if (JSON.parse(payload).type === 'ready') becameReady = true; }));
      await deniedTurn.goto(url); const failedAt = Date.now(); await deniedTurn.click('#connect');
      await deniedTurn.waitForFunction(() => !document.querySelector('#connect').disabled, null, {timeout: 25000});
      assert.equal(becameReady, false);
      await until(async () => (await sessions()) === 0);
      result.invalid_credentials_cleanup_ms = Date.now() - failedAt;
      await deniedTurn.close();
    }
    const interrupted = await context.newPage();
    await interrupted.goto(url); await interrupted.click('#connect');
    await interrupted.waitForFunction(() => document.querySelector('#connection').textContent.startsWith('Ready'));
    const lostAt = Date.now();
    await context.setOffline(true);
    await interrupted.waitForFunction(() => !document.querySelector('#connect').disabled, null, {timeout: 35000});
    await until(async () => (await sessions()) === 0);
    result.signaling_loss_cleanup_ms = Date.now() - lostAt;
    await context.close();
    console.log(JSON.stringify(result));
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
