const { chromium } = require('../validation/browser/node_modules/playwright');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
(async () => {
  const browser = await chromium.launch({ headless: true });
  const errors = [];
  const url = process.env.BOOKING_PREVIEW_URL || 'http://127.0.0.1:4994/blog/keep-talking-while-we-book-it/';
  for (const [label, width, height] of [['desktop',1440,1000], ['mobile',390,844]]) {
    const page = await browser.newPage({viewport:{width,height}});
    page.on('pageerror',error=>errors.push(error.message));
    await page.goto(url);
    await page.waitForFunction(()=>document.querySelectorAll('[data-booking-replay][data-ready="true"]').length===2);
    await page.evaluate(()=>document.fonts.ready);
    const clean = page.locator('#booking-clean'), cafe = page.locator('#booking-cafe');
    assert.deepEqual(await page.locator('[data-booking-replay]').evaluateAll(roots=>roots.map(r=>r.dataset.condition)),['clean','cafe']);
    for (const [root,prefix] of [[clean,'clean/'],[cafe,'']]) {
      assert.deepEqual(await root.locator('option').evaluateAll(options=>options.map(o=>o.value)),['openai','phonic','grok','gemini'].map(p=>prefix+p));
      assert.equal(await root.locator('audio').evaluate(a=>a.paused),true,'No autoplay');
    }
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false,`${label} page overflow`);
    async function selectRecording(root,name) {
      const base = new URL(await root.getAttribute('data-booking-replay'),page.url());
      const metadataUrl = new URL(name+'.json',base);
      const data = await (await page.request.get(metadataUrl.href)).json();
      const expected = new URL(data.audio,metadataUrl);
      expected.searchParams.set('v',data.audio_sha256.slice(0,12));
      await root.locator('select').selectOption(name);
      await page.waitForFunction(({id,src})=>{
        const r=document.getElementById(id);return r.dataset.ready==='true'&&r.querySelector('audio').src===src;
      },{id:await root.getAttribute('id'),src:expected.href});
      const actual = await root.locator('audio').evaluate(a=>a.src);
      const bytes = await (await page.request.get(actual)).body();
      assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'),data.audio_sha256,`${name} audio hash`);
      if(name.startsWith('clean/')) assert(!data.ambience,`${name} contains café ambience`);
      assert.equal(await root.locator('svg[data-waveform]').count(),2);
      assert.equal(await root.locator('[data-replay-activity-list] [data-state]').count(),0,'No future facts');
      assert(await root.locator('[data-replay-transcript] li').count()>0);
      if(!data.passed&&name==='gemini') assert.equal(await root.locator('[data-event="booking_confirmed"]').count(),0);
      return data;
    }
    for(const provider of ['gemini','grok','phonic','openai']) {
      await selectRecording(clean,'clean/'+provider);
      await selectRecording(cafe,provider);
      assert.equal(await clean.locator('select').inputValue(),'clean/'+provider,'Café selection changed clean selection');
    }
    await clean.locator('audio').evaluate(a=>{a.currentTime=15;});
    await selectRecording(cafe,'phonic');
    assert.equal(await clean.locator('audio').evaluate(a=>Math.round(a.currentTime)),15,'Café selection reset clean position');
    const primary=await selectRecording(cafe,'openai');
    await cafe.scrollIntoViewIfNeeded();
    const old=primary.backend_activity.find(j=>j.replaced_at!=null);
    const newer=primary.backend_activity.find(j=>j.operation==='availability'&&j.id!==old.id);
    async function seek(ms) {
      await cafe.locator('audio').evaluate((a,ms)=>{a.currentTime=ms/1000;},ms);
      await page.waitForFunction(ms=>Math.abs(document.querySelector('#booking-cafe audio').currentTime*1000-ms)<100,ms);
      const stamp=`${Math.floor(ms/60000)}:${String(Math.floor(ms/1000)%60).padStart(2,'0')}`;
      await page.waitForFunction(stamp=>document.querySelector('#booking-cafe [data-replay-activity-time]').textContent.startsWith(stamp),stamp);
    }
    await seek(old.start+1000);
    assert.match(await cafe.locator('[data-replay-activity-list]').textContent(),/Running/);
    assert(!/options returned|Appointment booked|simulated reminder was saved/.test(await cafe.locator('[data-replay-activity-list]').textContent()));
    await seek(newer.start+Math.min(300,(newer.end-newer.start)/2));
    assert.equal(await cafe.locator('[data-state="running"]').count(),2);
    assert.match(await cafe.locator('[data-replay-activity-list]').textContent(),/earlier action is still finishing/);
    await seek(newer.result.at+200);
    assert.match(await cafe.locator('[data-replay-activity-list]').textContent(),/appointment options returned/);
    assert.equal(await cafe.locator('[data-state="running"]').count(),1);
    for(const [event,pattern] of [['stale_result',/not passed into the conversation/],['booking_confirmed',/Appointment booked/],['reminder_saved',/simulated reminder was saved/]]) {
      await cafe.locator(`[data-event="${event}"]`).click();
      await cafe.locator('[data-replay-activity-list]').filter({hasText:pattern}).waitFor();
    }
    await seek(0);
    assert.equal(await cafe.locator('[data-replay-activity-list] [data-state]').count(),0,'Backward seek leaked future facts');
    await cafe.locator('.replay-moments button').first().focus();
    await page.keyboard.press('Enter');
    await cafe.locator('audio').evaluate(a=>a.play());
    await page.waitForTimeout(300);
    assert(await cafe.locator('audio').evaluate(a=>a.currentTime>0&&!a.paused));
    assert.notEqual(await cafe.locator('.replay-playhead').evaluate(e=>getComputedStyle(e).left),'auto');
    await page.locator('#reproduce').scrollIntoViewIfNeeded();
    await page.waitForTimeout(200);
    assert(await cafe.locator('audio').evaluate(a=>a.paused),'Out-of-view pause');
    // Starting a second player must pause the first, without resetting its clock.
    await page.evaluate(async()=>{
      const a=document.querySelector('#booking-clean audio'), b=document.querySelector('#booking-cafe audio');
      await a.play();await b.play();
      if(!a.paused||b.paused) throw Error('Both players can play at once');
      a.pause();b.pause();
    });
    await clean.scrollIntoViewIfNeeded();
    assert.equal(await page.locator('.booking-observability img').count(),2);
    assert.deepEqual(await page.locator('.booking-observability h3').allTextContents(),[
      'A new date while the old lookup runs','A progress reply while booking finishes']);
    assert(!/VictoriaMetrics|VictoriaTraces|replotted exports/.test(await page.locator('article').textContent()),'Storage-tool details returned to the article');
    assert.deepEqual(await page.locator('.booking-observability img').evaluateAll(images=>images.map(img=>new URL(img.src).pathname.split('/').at(-1))),[
      'lookup-correction.svg','booking-progress.svg']);
    for(const [i,figure] of (await page.locator('.booking-observability').all()).entries()) {
      await figure.scrollIntoViewIfNeeded();
      await figure.locator('img').evaluate(img=>img.decode());
      assert(await figure.locator('img').evaluate(img=>img.naturalWidth>0));
    }
    await page.evaluate(()=>scrollTo(0,0));
    await page.emulateMedia({reducedMotion:'reduce'});
    for(const head of await page.locator('.replay-playhead').all()) assert.equal(await head.evaluate(e=>getComputedStyle(e).display),'none');
    await page.close();
  }
  const linked=await browser.newPage();
  await linked.goto(url+'?recording=clean/gemini');
  await linked.waitForFunction(()=>document.querySelectorAll('[data-ready="true"]').length===2);
  assert.equal(await linked.locator('#booking-clean select').inputValue(),'clean/gemini');
  assert.equal(await linked.locator('#booking-cafe select').inputValue(),'openai');
  await linked.goto(url+'?recording=grok');
  await linked.waitForFunction(()=>document.querySelectorAll('[data-ready="true"]').length===2);
  assert.equal(await linked.locator('#booking-clean select').inputValue(),'clean/openai');
  assert.equal(await linked.locator('#booking-cafe select').inputValue(),'grok');
  await linked.close();
  const page=await browser.newPage({javaScriptEnabled:false});
  await page.goto(url);
  assert.equal(await page.locator('audio[controls]').count(),2);
  for(const condition of ['clean','cafe']) assert(await page.locator(`#booking-${condition} [data-replay-transcript] li`).count()>0);
  for(const [condition,prefix] of [['clean','clean/'],['cafe','']]) {
    const src=await page.locator(`#booking-${condition} audio source`).getAttribute('src');
    assert(new URL(src,page.url()).pathname.endsWith(`/assets/booking/${prefix}openai.mp3`),'Static player source missing');
    assert((await page.request.get(new URL(src,page.url()).href)).ok(),'Static audio unavailable');
  }
  assert.equal(await page.locator('article a[href*=".json"]').count(),0,'Raw evidence links in article');
  assert.equal(await page.locator('article a[href*=".mp3"]').count(),0,'Standalone audio downloads in article');
  await browser.close();
  assert.deepEqual(errors,[]);
  console.log('Booking article passed desktop/mobile, two independent players, eight audio hashes, lifecycle, real graphs, keyboard, reduced-motion, deep-link and no-JavaScript checks.');
})().catch(error=>{console.error(error);process.exit(1);});
