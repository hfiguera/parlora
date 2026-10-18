// Offline browser application test. Uses the consumer's demo SQLite database.
const assert = require('node:assert/strict');
const {chromium} = require('playwright');
(async () => {
  const browser = await chromium.launch({channel: process.env.BROWSER_CHANNEL || undefined, headless: true});
  try {
    const page = await browser.newPage();
    const errors = []; page.on('pageerror', error => errors.push(error.message));
    await page.goto(process.env.BROWSER_URL || 'http://localhost:4000');
    await page.waitForSelector('#order-825');
    const before = await page.evaluate(() => fetch('/api/orders').then(r => r.json()));
    const version = before.orders.find(o => o.id === '825').version;
    await page.locator('#order-825 input').fill('Leave it at reception');
    await page.locator('#order-825 button').click();
    const confirm = page.getByRole('button', {name: 'Confirm update to order 825'}).first();
    await confirm.waitFor();
    const id = await confirm.locator('..').getAttribute('data-proposal');
    await confirm.click();
    await page.waitForFunction(() => document.activeElement.id === 'proposal-notice');
    await page.waitForFunction(v => document.querySelector('#order-825 [data-field=version]').textContent === `Record version ${v}`, version + 1);
    const replay = await page.evaluate(async ({id, csrf}) => {
      const response = await fetch(`/api/proposals/${id}/confirm`, {method: 'POST', headers: {'x-csrf-token': csrf}});
      return response.json();
    }, {id, csrf: before.csrf});
    assert.equal(replay.result.duplicate, true);
    await page.reload(); await page.waitForSelector('#order-825');
    assert.match(await page.locator('#order-825 [data-field=instructions]').textContent(), /reception/);
    assert.equal(await page.locator('#order-825 [data-field=version]').textContent(), `Record version ${version + 1}`);
    await page.locator('#order-825 input').fill('Leave it with the neighbor');
    await page.locator('#order-825 button').click();
    await page.getByRole('button', {name: 'Reject draft'}).first().click();
    await page.waitForFunction(() => /rejected/.test(document.querySelector('#proposals').textContent));
    assert.equal(await page.locator('#order-825 [data-field=version]').textContent(), `Record version ${version + 1}`);
    // Failed confirmation remains retryable and never claims a save.
    await page.locator('#order-825 input').fill('Leave it at the front desk');
    await page.locator('#order-825 button').click();
    const retryConfirm = page.getByRole('button', {name: 'Confirm update to order 825'}).first();
    await retryConfirm.waitFor();
    const retryId = await retryConfirm.locator('..').getAttribute('data-proposal');
    await page.route(`**/api/proposals/${retryId}/confirm`, route => route.fulfill({status: 503, body: '{}'}));
    await retryConfirm.click();
    await page.waitForFunction(() => document.querySelector('#proposal-notice').dataset.kind === 'error');
    assert.match(await page.locator('#proposal-notice').textContent(), /Try again/);
    assert.equal(await page.locator('#order-825 [data-field=version]').textContent(), `Record version ${version + 1}`);
    await page.unroute(`**/api/proposals/${retryId}/confirm`);
    await retryConfirm.click();
    await page.waitForFunction(v => document.querySelector('#order-825 [data-field=version]').textContent === `Record version ${v}`, version + 2);
    // Refreshing data does not overwrite a delivery instruction being edited.
    await page.locator('#order-123 input').fill('An unfinished edit');
    await page.waitForTimeout(2200);
    assert.equal(await page.locator('#order-123 input').inputValue(), 'An unfinished edit');
    await page.route('**/api/orders', route => route.fulfill({status: 503, body: '{}'}));
    await page.locator('#retry-orders').waitFor({state: 'visible'});
    assert.match(await page.locator('#order-notice').textContent(), /out of date/);
    await page.unroute('**/api/orders');
    await page.locator('#retry-orders').click();
    await page.locator('#retry-orders').waitFor({state: 'hidden'});
    assert.equal(await page.locator('#order-notice').textContent(), '');
    // Keyboard entry and enlarged text remain usable on narrow screens.
    await page.reload(); await page.waitForSelector('#order-123');
    await page.keyboard.press('Tab');
    assert.equal(await page.locator(':focus').textContent(), 'Skip to your orders');
    assert.equal(await page.locator(':focus').evaluate(n => getComputedStyle(n).outlineStyle), 'solid');
    await page.keyboard.press('Enter');
    assert.equal(await page.locator(':focus').getAttribute('id'), 'orders-heading');
    for (const width of [1280, 768, 375, 320]) {
      await page.setViewportSize({width, height: 900});
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth), width);
    }
    await page.evaluate(() => document.documentElement.style.fontSize = '200%');
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth), 320);
    assert.deepEqual(errors, []);
    console.log('ORDER_UI', JSON.stringify({save: true, reload: true, duplicate_prevented: true, rejection: true, confirmation_focus: true, failed_confirmation_retry: true, refresh_recovery: true, edit_preserved: true, keyboard_entry: true, responsive_large_text: true, page_errors: 0}));
  } finally { await browser.close(); }
})().catch(error => {console.error(error); process.exitCode = 1;});
