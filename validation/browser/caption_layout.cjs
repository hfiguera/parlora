'use strict';
// Synthetic rendering only: canonical HTML/CSS and caption callback, no voice,
// microphone, API requests, or database writes.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require('playwright');
const output = path.resolve(process.argv[2] || '');
if (!process.argv[2]) throw new Error('Usage: node validation/browser/caption_layout.cjs NEW_OUTPUT');
fs.mkdirSync(output);
const assets = path.resolve(__dirname, '../../examples/order_desk/priv/browser');
const source = fs.readFileSync(path.join(assets, 'voice.js'), 'utf8');
const callback = source.slice(source.indexOf('const caption ='), source.indexOf('const receive ='));
const html = fs.readFileSync(path.join(assets, 'index.html'), 'utf8')
  .replace('<link rel="stylesheet" href="/style.css">', `<style>${fs.readFileSync(path.join(assets, 'style.css'), 'utf8')}</style>`)
  .replace(/<script[^>]*><\/script>/g, '');
const expected = ['AssistantPlease confirm the draft for order 124.', "AssistantSaying yes won’t save it. ",
  'AssistantJust to note, order 124 has saved the instruction: left in my front door.'];
(async () => {
  const browser = await chromium.launch({channel: process.env.BROWSER_CHANNEL || 'chrome', headless: true});
  const report = {fixture: 'Synthetic caption rendering, no live provider or listening', viewports: []};
  try {
    const page = await browser.newPage();
    const errors = []; page.on('pageerror', error => errors.push(error.message));
    for (const [name, width] of [['desktop', 1280], ['mobile', 375]]) {
      await page.setViewportSize({width, height: 900});
      await page.setContent(html);
      await page.addScriptTag({content: `(() => { let captions = [], captionEpoch = 0; const el = id => document.getElementById(id); ${callback}
        caption({speaker:'assistant', delta:'Please confirm the draft for order 1', start_ms:1000, end_ms:2500});
        caption({speaker:'assistant', delta:'24.', start_ms:2500, end_ms:3000});
        caption({speaker:'assistant', delta:'Saying yes won’t save it. Just to note, order 124 has saved the instruction: left in my front door.', start_ms:4800, end_ms:8000}); })();`});
      assert.deepEqual(errors, [], 'Caption callback raised a browser error');
      const rows = await page.locator('#transcript p').allTextContents();
      assert.deepEqual(rows, expected);
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth), width);
      const screenshot = `${name}.png`;
      await page.locator('.conversation-panel').screenshot({path: path.join(output, screenshot)});
      report.viewports.push({name, width, rows, screenshot, status:'passed'});
    }
    report.status = 'passed';
  } catch (error) {report.status = 'failed'; report.error = error.message; process.exitCode = 1;}
  finally {
    await browser.close();
    fs.writeFileSync(path.join(output, 'report.json'), JSON.stringify(report, null, 2));
    console.log(JSON.stringify(report));
  }
})().catch(error => {console.error(error); process.exitCode = 1;});
