// Bounded macOS acoustic caller; run only against an explicitly started live consumer.
if (process.env.PARLORA_BROWSER_LIVE !== '1') throw new Error('Set PARLORA_BROWSER_LIVE=1 to run the live microphone test');
const assert = require('node:assert/strict');
const {chromium} = require('playwright');
const {promisify} = require('node:util'); const execFile = promisify(require('node:child_process').execFile);
(async () => {
 const browser = await chromium.launch({channel:'chrome', headless:false});
 const context = await browser.newContext({permissions:['microphone']});
 const page = await context.newPage(); const messages = []; const started = Date.now();
 page.on('websocket', ws => ws.on('framereceived', event => {const m=JSON.parse(event.payload); if(messages.length<10000)messages.push({...m,elapsed_ms:Date.now()-started});}));
 try {
  await page.goto(process.env.BROWSER_URL || 'http://localhost:4000'); await page.click('#connect');
  await page.waitForFunction(() => document.querySelector('#connection').textContent.startsWith('Ready'),null,{timeout:20000});
  await page.locator('#playback-controls > summary').click();
  await page.locator('#diagnostics > summary').click();
  await page.waitForTimeout(5000);
  async function speak(text) { await page.click('#stop'); await page.waitForTimeout(250); await execFile('/usr/bin/say',['-r','190',text],{timeout:15000}); await page.click('#resume'); }
  await speak('Please check the delivery status of order one hundred twenty three.');
  for(let i=0;i<40 && !messages.some(m=>m.event==='request_started');i++) await page.waitForTimeout(100);
  await speak('Actually, I made a mistake. Please check order one hundred twenty four.');
  await page.waitForFunction(() => /out for delivery/i.test(document.querySelector('#transcript').textContent),null,{timeout:35000});
  await page.waitForTimeout(3000); await page.click('#status'); await page.waitForTimeout(300);
  const jobs = Object.values(messages.findLast(m => m.type === 'status').status.jobs);
  assert.equal(jobs.length, 2);
  assert(jobs.some(job => job['current?'] && job.delivery === 'accepted'));
  assert(jobs.some(job => !job['current?'] && job.delivery === 'stale'));
  console.log('CAPTIONS',await page.locator('#transcript').textContent());
  console.log('RESULT_EVENTS',JSON.stringify(messages.filter(m=> m.type==='status'|| ['request_started','request_completed','result_delivery','delegation_associated'].includes(m.event))));
  const route = await page.evaluate(() => window.parloraConnectionPath());
  if (process.env.EXPECT_RELAY === '1') { assert.equal(route.local, 'relay'); assert.equal(route.remote, 'relay'); }
  console.log('MEDIA_PATH', JSON.stringify(route));
  const stats=await page.evaluate(()=>window.parloraBrowserStats());
  console.log('AUDIO_STATS',JSON.stringify(stats.filter(s=>['inbound-rtp','outbound-rtp','media-playout'].includes(s.type))));
  console.log('DISCONTINUITIES',JSON.stringify(messages.filter(m=>m.event==='audio_discontinuity').reduce((a,m)=>(a[m.payload.cause]=(a[m.payload.cause]||0)+1,a),{})));
  await page.click('#disconnect');
 } catch(e) {console.log('ERROR',e.message); console.log('CAPTIONS',await page.locator('#transcript').textContent({timeout:1000}).catch(()=>'(page unavailable)')); console.log('EVENTS',JSON.stringify(messages.filter(m=>m.type!=='transcript'&&m.event!=='audio_discontinuity')));process.exitCode=1;}
 finally {await browser.close();}
})();
