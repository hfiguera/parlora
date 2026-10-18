// Bounded live greeting probe with a muted synthetic microphone; no acoustic input.
const {chromium} = require('../browser/node_modules/playwright');
const fs = require('node:fs');
const assert = require('node:assert/strict');
(async () => {
  const browser = await chromium.launch({channel:'chrome', headless:true,args:['--use-fake-device-for-media-stream','--use-fake-ui-for-media-stream']});
  const context = await browser.newContext({permissions:['microphone']});
  await context.addInitScript(() => { const get = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices); navigator.mediaDevices.getUserMedia = async (...args) => { const stream = await get(...args); stream.getAudioTracks().forEach(t => t.enabled = false); return stream; }; });
  const page = await context.newPage(); const events=[]; const errors=[]; const start=Date.now();
  page.on('pageerror', e=>errors.push(e.message));
  page.on('websocket',ws=>ws.on('framereceived',({payload})=>{const m=JSON.parse(payload); if(events.length<3000 && !['signal'].includes(m.type)) events.push({...m, elapsed_ms:Date.now()-start});}));
  try {
    await page.goto('http://localhost:4000'); await page.click('#connect');
    await page.waitForFunction(()=>document.querySelector('#connection').textContent.startsWith('Ready'),null,{timeout:15000});
    await page.waitForTimeout(12000);
    await page.locator('#diagnostics > summary').click(); await page.click('#status'); await page.waitForTimeout(300);
    const captions=await page.locator('#transcript').textContent();
    const stats=await page.evaluate(()=>window.parloraBrowserStats());
    await page.click('#disconnect');
    const safeEvents=events.filter(m=>!['attached','answer','candidate'].includes(m.type));
    const report={captions, errors, events:safeEvents, stats:stats.filter(r=>['inbound-rtp','outbound-rtp'].includes(r.type))};
    fs.writeFileSync(process.env.PROBE_OUTPUT,JSON.stringify(report,null,2)+'\n');
    console.log(JSON.stringify({captions,errors,events:safeEvents.filter(e=>e.type==='status'||e.type==='transcript'||e.event==='context_rejected')},null,2));
    if (process.env.EXPECT_GREETING === '1') {
      assert.equal(errors.length, 0, 'no browser exceptions');
      assert(safeEvents.some(e => e.type === 'transcript' && e.payload.speaker === 'assistant'), 'assistant greets without caller speech');
      assert(stats.some(r => r.type === 'inbound-rtp' && r.totalAudioEnergy > 0.00001), 'non-silent audio reaches browser decoding');
      assert(!safeEvents.some(e => ['failed','context_rejected'].includes(e.event)), 'no session failure or rejected context');
    }
  } finally { await browser.close(); }
})().catch(e=>{console.error(e);process.exitCode=1;});
