// Paid GPT-Live/TypeSafe call and synthetic delivery update. Use an isolated demo DB.
if (process.env.ORDER_DESK_LIVE_TEST !== '1') throw new Error('Set ORDER_DESK_LIVE_TEST=1 with an isolated demo database');
const assert = require('node:assert/strict');
const {chromium} = require('playwright');
const {promisify} = require('node:util');
const execFile = promisify(require('node:child_process').execFile);
(async () => {
  const browser = await chromium.launch({channel: 'chrome', headless: false});
  const context = await browser.newContext({permissions: ['microphone']});
  const page = await context.newPage();
  const started = Date.now();
  try {
    await page.goto(process.env.BROWSER_URL || 'http://localhost:4007');
    await page.waitForSelector('#order-124');
    const initial = await page.locator('#order-124 [data-field=instructions]').textContent();
    await page.click('#connect');
    await page.waitForFunction(() => document.querySelector('#connection').textContent.startsWith('Ready'), null, {timeout: 20000});
    await page.locator('#playback-controls > summary').click();
    await page.locator('#diagnostics > summary').click();
    await page.waitForTimeout(4000);
    async function speak(text) {
      await page.click('#stop'); await page.waitForTimeout(250);
      await execFile('/usr/bin/say', ['-r', '185', text], {timeout: 20000});
      await page.click('#resume');
    }
    await speak('Please check the delivery status of order one hundred twenty three.');
    await page.waitForTimeout(2000);
    await speak('Actually I meant order one hundred twenty four.');
    await page.waitForFunction(() => /out for delivery/i.test(document.querySelector('#transcript').textContent), null, {timeout: 18000});
    await speak('What items are in that order?');
    await page.waitForFunction(() => /desk lamp/i.test(document.querySelector('#transcript').textContent), null, {timeout: 18000});
    await speak('For order one hundred twenty four, change the delivery instructions to leave it at reception.');
    await page.getByRole('button', {name: 'Confirm update to order 124'}).first().waitFor({timeout: 20000});
    assert.equal(await page.locator('#order-124 [data-field=instructions]').textContent(), initial);
    await speak('No, leave the instructions as they are.');
    await page.waitForTimeout(3000);
    assert.equal(await page.locator('#order-124 [data-field=instructions]').textContent(), initial);
    // The explicit browser action, never the voice judgment, authorizes this exact draft.
    await page.getByRole('button', {name: 'Confirm update to order 124'}).first().click();
    await page.waitForFunction(() => /reception/i.test(document.querySelector('#order-124 [data-field=instructions]').textContent), null, {timeout: 5000});
    const dashboard = await page.evaluate(() => fetch('/api/orders').then(r => r.json()));
    console.log('APP_LIVE', JSON.stringify({elapsed_ms: Date.now() - started, correction: true, items: true, voice_draft: true, refusal_did_not_write: true, explicit_confirmation_saved: true, changes: dashboard.changes.length, interpretation: dashboard.interpretation}));
    console.log('CAPTIONS', await page.locator('#transcript').textContent());
    await page.click('#disconnect');
  } catch (error) {
    console.log('APP_LIVE_ERROR', error.message);
    console.log('CAPTIONS', await page.locator('#transcript').textContent().catch(() => '(unavailable)'));
    console.log('EVENTS', await page.locator('#events').textContent().catch(() => '(unavailable)'));
    process.exitCode = 1;
  } finally { await browser.close(); }
})().catch(error => {console.error(error); process.exitCode = 1;});
