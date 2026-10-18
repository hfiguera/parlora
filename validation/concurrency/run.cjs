'use strict';
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),net=require('node:net'),crypto=require('node:crypto');
const {spawn,execFileSync}=require('node:child_process');
const {chromium}=require('../browser/node_modules/playwright');
const {verifyConsumer}=require('../release/provenance.cjs');
const root=path.resolve(__dirname,'../..'),consumer=path.resolve(process.argv[2]||''),out=path.resolve(process.argv[3]||'');
if(!fs.existsSync(path.join(consumer,'mix.exs'))||out===process.cwd())throw Error('Usage: node validation/concurrency/run.cjs CONSUMER NEW_OUTPUT');
fs.mkdirSync(path.dirname(out),{recursive:true});
fs.mkdirSync(out,{mode:0o700});
const digest=f=>crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex');
const report={schema:1,status:'running',started_at:new Date().toISOString(),git_revision:process.env.CONCURRENCY_SOURCE_REVISION||execFileSync('git',['rev-parse','HEAD'],{cwd:root,encoding:'utf8'}).trim(),revision_source:process.env.CONCURRENCY_SOURCE_REVISION?'explicit source snapshot':'git',
 plan:{concurrency:[1,2,4],faults:['stall','disconnect'],admission_limit:4,work_per_healthy_session:3,provider:'local scripted paced tones',backend:'real Jido shared application instance'},
 platform:{os:process.platform,arch:process.arch,node:process.version,browser_args:['--autoplay-policy=no-user-gesture-required','--disable-background-timer-throttling','--disable-renderer-backgrounding']},sources:{},consumer_sources:verifyConsumer(root,consumer),cohorts:[]};
for(const f of ['run.cjs','client.js','server.exs','analyze.py'])report.sources[f]=digest(path.join(__dirname,f));
function save(){fs.writeFileSync(path.join(out,'report.json'),JSON.stringify(report,null,2)+'\n');}
let child,browser,url,contexts=[],stopping=false;
const pause=ms=>new Promise(r=>setTimeout(r,ms));
async function until(fn,label,ms=15000){const end=Date.now()+ms;while(Date.now()<end){const v=await fn();if(v)return v;await pause(50);}throw Error('Timed out: '+label);}
async function state(){const r=await fetch(url+'/state',{signal:AbortSignal.timeout(6000)});assert(r.ok);return r.json();}
async function command(tag,action,round=0){const r=await fetch(`${url}/command/${tag}/${action}/${round}`,{method:'POST',signal:AbortSignal.timeout(6000)});assert.equal(r.status,200);}
async function connect(slot,tag,gate=false){
 const context=await browser.newContext();contexts.push(context);const page=await context.newPage();
 page.on('pageerror',e=>{report.page_errors??=[];report.page_errors.push({tag,error:e.message});});
 const query=new URLSearchParams({slot:String(slot),socket:gate?'/gate':`/socket/${slot}/${tag}`});
 await page.goto(url+'/?'+query);await page.click('#start');
 return {page,context,slot,tag};
}
async function ready(client){await client.page.waitForFunction(()=>window.probe.ready||window.probe.closed,null,{timeout:15000});assert(await client.page.evaluate(()=>window.probe.ready&&!window.probe.closed),'Call did not become ready: '+client.tag);}
async function closeClients(clients){
 await Promise.allSettled(clients.map(async c=>{await c.page.evaluate(()=>window.disconnectProbe?.());await c.page.waitForFunction(()=>window.probe.closed,null,{timeout:12000});}));
}
function audio(pcm,rate,slot,direction,tag){
 const frequencies=direction==='input'?[700,1100,1500,1900]:[500,900,1300,1700];
 const target=path.join(out,`${tag}-${direction}-analysis.json`);
 execFileSync('python3',[path.join(__dirname,'analyze.py'),pcm,'--rate',String(rate),'--expected',String(frequencies[slot-1]),'--frequencies',frequencies.join(','),'--output',target],{stdio:'pipe'});
 return JSON.parse(fs.readFileSync(target));
}
async function cohort(n,mode){
 const name=`${mode}-${n}`,started=Date.now(),before=await state(),clients=[];
 const result={name,n,mode,status:'running'};report.cohorts.push(result);save();
 try{
  clients.push(...await Promise.all(Array.from({length:n},(_,i)=>connect(i+1,`${name}-s${i+1}`))));
  await Promise.all(clients.map(ready));
  assert.equal((await state()).active,n);
  result.overlap_started_at_ms=Date.now();
  await Promise.all(clients.map(c=>command(c.tag,'start')));
  await pause(1000);
  const healthy=mode==='stall'||mode==='disconnect'?clients.slice(1):clients;
  async function work(list,round){
   await Promise.all(list.map(c=>command(c.tag,'request',round)));
   await until(async()=>{const s=await state();return list.every(c=>s.sessions[c.tag].captions.some(x=>x.speaker==='assistant'&&x.delta===`${c.tag}:job${round}`));},'isolated results for round '+round,7000);
  }
  await work(clients,1);
  await pause(mode==='warmup'?1000:4000);
  if(healthy.length!==clients.length){
   result.fault_at_ms=Date.now();
   result.neighbor_before=await Promise.all(healthy.map(c=>c.page.evaluate(()=>window.sampleProbe())));
   await command(clients[0].tag,mode);
   await Promise.all([
    work(healthy,2).then(()=>{result.neighbor_work_ms=Date.now()-result.fault_at_ms;}),
    until(async()=> (await state()).sessions[clients[0].tag].closed,'fault session cleanup',7500).then(()=>{result.fault_cleanup_ms=Date.now()-result.fault_at_ms;})
   ]);
   const s=await state();assert.equal(s.active,n-1);
   if(mode==='stall')assert.equal(s.sessions[clients[0].tag].failure.cause,'progress_timeout');
   assert(result.neighbor_work_ms<result.fault_cleanup_ms,'Neighbors did not finish work during failure cleanup');
  }else{await work(healthy,2);}
  await pause(mode==='warmup'?1000:3000);
  await work(healthy,3);await pause(mode==='warmup'?1000:3000);
  for(const c of healthy){assert(await c.page.evaluate(()=>window.probe.ready&&!window.probe.closed),'Neighbor stopped');}
  if(healthy.length!==clients.length){
   const after=await Promise.all(healthy.map(c=>c.page.evaluate(()=>window.sampleProbe())));
   assert(after.every((s,i)=>s.captured>result.neighbor_before[i].captured+48000),'Neighbor audio did not advance after fault');
   result.neighbor_audio_advanced=true;delete result.neighbor_before;
  }
  result.measurement_finished_at_ms=Date.now();
  await closeClients(clients);
  await until(async()=>{const s=await state();return s.active===0&&s.tracked_alive===0;},'all sampled session resources released');
  await pause(500);
  const after=await state();result.cleanup={active:after.active,tracked_alive:after.tracked_alive};
  result.sessions=[];
  for(const c of clients){
   const captured=await c.page.evaluate(()=>window.exportProbe());
   fs.writeFileSync(path.join(out,c.tag+'-output.pcm'),Buffer.from(captured.pcm,'base64'));delete captured.pcm;
   fs.writeFileSync(path.join(out,c.tag+'-browser.json'),JSON.stringify(captured,null,2));
   const e=after.sessions[c.tag],expected=healthy.includes(c)?3:1;
   assert.equal(e.jobs.length,expected);assert.equal(e.results.length,expected);
   const markers=Array.from({length:expected},(_,i)=>`${c.tag}:job${i+1}`);
   assert.deepEqual(e.jobs.map(j=>j.marker),markers);assert.deepEqual(e.results,markers);
   assert(e.captions.every(x=>markers.includes(x.delta)),'Caption from another session');
   assert(captured.events.filter(e=>e.type==='transcript').every(e=>markers.includes(e.payload.delta)),'Browser received foreign caption');
   assert(!captured.error&&!captured.captureError&&!captured.truncated,'Capture failure');
   assert(e.response_ms.length===expected);assert(e.metrics.queue_peak<=33600);
   const media=captured.events.filter(e=>e.type==='status'&&e.media?.input_bytes!==undefined).map(e=>e.media);
   assert(media.length>0,'No browser queue samples');
   const queues={input_peak_bytes:Math.max(...media.map(m=>m.input_bytes)),output_peak_bytes:Math.max(...media.map(m=>m.output_bytes)),rtp_peak_packets:Math.max(...media.map(m=>m.rtp_queued)),max_tick_gap_us:Math.max(...media.map(m=>m.max_tick_gap_us))};
   assert(queues.input_peak_bytes<=19200&&queues.output_peak_bytes<=10560&&queues.rtp_peak_packets<=32,'Browser storage exceeded configured bounds plus staging');
   const input=audio(path.join(out,c.tag+'-input.pcm'),24000,c.slot,'input',c.tag);
   const output=audio(path.join(out,c.tag+'-output.pcm'),captured.rate,c.slot,'output',c.tag);
   result.sessions.push({tag:c.tag,slot:c.slot,session_id:e.id,jobs:expected,response_ms:e.response_ms,input,output,browser_queues:queues,provider:e.metrics,
    browser_report_sha256:digest(path.join(out,c.tag+'-browser.json')),input_sha256:digest(path.join(out,c.tag+'-input.pcm')),output_sha256:digest(path.join(out,c.tag+'-output.pcm'))});
  }
  const start=before.vm.at(-1).at_us,end=after.vm.at(-1).at_us,vm=after.vm.filter(x=>x.at_us>=start&&x.at_us<=end);
  result.metrics={wall_ms:(end-start)/1000,cpu_ms:vm.at(-1).cpu_ms-vm[0].cpu_ms,
   beam_peak_bytes:Math.max(...vm.map(x=>x.beam_bytes)),beam_after_bytes:vm.at(-1).beam_bytes,process_peak:Math.max(...vm.map(x=>x.processes)),
   processes_after:vm.at(-1).processes,max_mailbox:Math.max(...vm.map(x=>x.max_mailbox)),max_active:Math.max(...vm.map(x=>x.active)),
   rss_after_kib:Number(execFileSync('ps',['-p',after.beam_pid,'-o','rss='],{encoding:'utf8'}).trim())};
  assert.equal(result.metrics.max_active,n);result.status='passed';
 }catch(e){result.status='failed';result.error=e.message;throw e;}
 finally{
  await closeClients(clients);
  for(const c of clients){try{if(!fs.existsSync(path.join(out,c.tag+'-browser.json'))){const captured=await c.page.evaluate(()=>window.exportProbe());fs.writeFileSync(path.join(out,c.tag+'-output.pcm'),Buffer.from(captured.pcm,'base64'));delete captured.pcm;fs.writeFileSync(path.join(out,c.tag+'-browser.json'),JSON.stringify(captured,null,2));}}catch(_) {}}
  try{fs.writeFileSync(path.join(out,name+'-server.json'),JSON.stringify(await state(),null,2));}catch(_){}
  await Promise.allSettled(clients.map(c=>c.context.close()));contexts=contexts.filter(c=>!clients.some(x=>x.context===c));
  result.duration_ms=Date.now()-started;save();console.log(`${result.status}: ${name}${result.error?' — '+result.error:''}`);
 }
}
async function admission(){
 const clients=[];report.admission={status:'running'};save();
 try{
  clients.push(...await Promise.all(Array.from({length:4},(_,i)=>connect(i+1,'gate'+i,true))));
  await Promise.all(clients.map(ready));assert.equal((await state()).gate_active,4);
  const fifth=await connect(1,'rejected',true);clients.push(fifth);
  await fifth.page.waitForFunction(()=>window.probe.closed,null,{timeout:10000});
  const rejected=await fifth.page.evaluate(()=>({ready:window.probe.ready,code:window.probe.closeCode}));
  assert.equal(rejected.ready,false);assert.equal(rejected.code,1011);assert.equal((await state()).gate_active,4);
  await closeClients([clients[0]]);await until(async()=>(await state()).gate_active===3,'gate releases one slot');
  const replacement=await connect(1,'replacement',true);clients.push(replacement);await ready(replacement);
  assert.equal((await state()).gate_active,4);
  for(const c of clients.slice(1,4))assert(await c.page.evaluate(()=>window.probe.ready&&!window.probe.closed));
  report.admission={status:'passed',simultaneous_ready:4,fifth:rejected,replacement_ready:true};
 }finally{await closeClients(clients);await Promise.allSettled(clients.map(c=>c.context.close()));contexts=[];
  await until(async()=>{const s=await state();return s.active===0&&s.gate_active===0&&s.tracked_alive===0;},'admission cleanup');save();}
}
async function stop(){if(stopping)return;stopping=true;
 await Promise.allSettled(contexts.map(c=>c.close()));if(browser)await browser.close();
 if(child&&child.exitCode===null){try{process.kill(-child.pid,'SIGTERM');}catch(_){}await pause(1000);if(child.exitCode===null)try{process.kill(-child.pid,'SIGKILL');}catch(_){}}
}
for(const sig of ['SIGINT','SIGTERM'])process.once(sig,async()=>{report.status='failed';report.error='Interrupted';save();await stop();process.exit(130);});
(async()=>{
 const port=await new Promise(resolve=>{const s=net.createServer().listen(0,'127.0.0.1',()=>{const p=s.address().port;s.close(()=>resolve(p));});});url=`http://127.0.0.1:${port}`;
 const env={...process.env,MIX_ENV:'dev',ERL_FLAGS:'+sbwt none +sbwtdcpu none +sbwtdio none',ORDER_DESK_TYPESAFE:'0',ORDER_DESK_DATABASE:path.join(out,'fixture.sqlite3'),PORT:String(port),CONCURRENCY_OUTPUT:out};
 delete env.OPENAI_API_KEY;delete env.TYPESAFE_API_KEY;
 if(process.platform==='darwin'&&process.arch==='arm64')env.RUSTUP_TOOLCHAIN='1.92.0-aarch64-apple-darwin';
 const fd=fs.openSync(path.join(out,'server.log'),'a',0o600);
 child=spawn('mix',['run',path.join(__dirname,'server.exs')],{cwd:consumer,env,detached:true,stdio:['ignore',fd,fd]});fs.closeSync(fd);
 await until(async()=>{if(child.exitCode!==null)throw Error('Fixture server exited');try{const r=await fetch(url+'/state');return r.ok&&(await r.json()).vm.length>0;}catch(_){return false;}},'server',120000);
 browser=await chromium.launch({headless:true,args:['--autoplay-policy=no-user-gesture-required','--disable-background-timer-throttling','--disable-renderer-backgrounding']});
 report.browser=browser.version();
 await cohort(4,'warmup');
 for(const n of [1,2,4])await cohort(n,'normal');
 await cohort(4,'stall');await cohort(4,'disconnect');await admission();
 const final=await state();fs.writeFileSync(path.join(out,'server-observations.json'),JSON.stringify(final,null,2));
 report.cleanup={active:final.active,gate_active:final.gate_active,tracked_alive:final.tracked_alive};
 assert(!report.page_errors?.length,'Browser errors');
 const first=report.cohorts[0].metrics,last=report.cohorts.at(-1).metrics;
 assert(last.beam_after_bytes<=first.beam_after_bytes+16_000_000,'Post-warmup BEAM growth exceeded 16 MB');
 assert(last.processes_after<=first.processes_after+10,'Post-warmup processes did not settle');
 const percentile=(values,p)=>{values=[...values].sort((a,b)=>a-b);return values[Math.ceil(values.length*p)-1];};
 report.comparison=report.cohorts.filter(c=>c.mode==='normal').map(c=>{const values=c.sessions.flatMap(s=>s.response_ms);return {sessions:c.n,observations:values.length,p50_ms:percentile(values,.5),p95_ms:percentile(values,.95),max_ms:Math.max(...values),cpu_equivalent_cores:c.metrics.cpu_ms/c.metrics.wall_ms};});
 const latencyLimit=Math.max(report.comparison[0].p95_ms*2,report.comparison[0].p95_ms+250);
 report.latency_gate={limit_ms:latencyLimit,definition:'p95 <= max(2 * same-run single-call p95, single-call p95 + 250 ms); includes scripted 200 ms work, not a speech SLA'};
 assert(report.comparison.every(c=>c.p95_ms<=latencyLimit),'Concurrent response degradation exceeded fixture budget');
 report.status='passed';
})().catch(e=>{report.status='failed';report.error=e.message;process.exitCode=1;console.error(e.message);}).finally(async()=>{await stop();report.finished_at=new Date().toISOString();save();});
