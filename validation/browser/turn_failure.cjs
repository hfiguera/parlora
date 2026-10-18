// Disrupts ONLY the dedicated Linux validation service; restores it in finally.
if (process.env.PARLORA_TURN_FAILURE_TEST !== '1') throw new Error('Set PARLORA_TURN_FAILURE_TEST=1 to stop/restart the test TURN service');
const assert = require('node:assert/strict');
const {chromium} = require('playwright');
const {promisify} = require('node:util');
const execFile = promisify(require('node:child_process').execFile);
const url = process.env.BROWSER_URL || 'http://localhost:4002';
const host = process.env.TURN_SSH_HOST || 'linux';
const control = action => execFile('ssh', [host, `systemctl --user ${action} parlora-turn.service`], {timeout: 10000});
(async () => {
  const browser = await chromium.launch({channel: process.env.BROWSER_CHANNEL || undefined,
    args: ['--use-fake-device-for-media-stream'], headless: true});
  try {
    const context = await browser.newContext({permissions: ['microphone']});
    const page = await context.newPage();
    await page.goto(url); await page.click('#connect');
    await page.waitForFunction(() => document.querySelector('#connection').textContent.startsWith('Ready'));
    const route = await page.evaluate(() => window.parloraConnectionPath());
    assert.equal(route.local, 'relay'); assert.equal(route.remote, 'relay');
    await control('stop'); const lostAt = Date.now();
    await page.waitForFunction(() => !document.querySelector('#connect').disabled, null, {timeout: 60000});
    const deadline = Date.now() + 6000;
    while ((await (await fetch(`${url}/health`)).json()).active_sessions !== 0) {
      assert(Date.now() < deadline, 'Session remained alive after media loss');
      await page.waitForTimeout(100);
    }
    const failure = {turn_loss_cleanup_ms: Date.now() - lostAt, closed: true};
    await control('start');
    await page.waitForTimeout(500);
    assert.equal((await (await fetch(`${url}/health`)).json()).active_sessions, 0);
    await page.click('#connect');
    await page.waitForFunction(() => document.querySelector('#connection').textContent.startsWith('Ready'));
    const recovered = await page.evaluate(() => window.parloraConnectionPath());
    assert.equal(recovered.local, 'relay'); assert.equal(recovered.remote, 'relay');
    await page.click('#disconnect');
    console.log(JSON.stringify({...failure, explicit_reconnect: true}));
  } finally { await browser.close(); await control('start'); }
})().catch(error => { console.error(error.message); process.exitCode = 1; });
