'use strict';
// Exactly two simultaneous, read-only synthetic calls on one consumer BEAM.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),net=require('node:net'),crypto=require('node:crypto');
const {spawn,execFileSync}=require('node:child_process');
const {chromium}=require('../browser/node_modules/playwright');
const {prepareAudio}=require('../acceptance/live.cjs');
const {assertSessionOpen}=require('../acceptance/assertions.cjs');
const {expectReply,resultBoundary}=require('../task-pilot/outcomes.cjs');
const {verifyConsumer}=require('../release/provenance.cjs');
const root=path.resolve(__dirname,'../..'),[consumerArg,outArg,gateArg,flag]=process.argv.slice(2);
if(flag!=='--live'||!consumerArg||!outArg||!gateArg||process.platform!=='darwin')throw Error('Usage (paid, macOS): node validation/concurrency/live.cjs CONSUMER NEW_OUTPUT PASSED_OFFLINE_REPORT --live');
const consumer=path.resolve(consumerArg),out=path.resolve(outArg),gate=JSON.parse(fs.readFileSync(gateArg));
assert.equal(gate.status,'passed');assert.equal(gate.admission.status,'passed');assert.equal(gate.cleanup.active,0);
assert.deepEqual(gate.cohorts.filter(c=>c.mode==='normal').map(c=>c.n),[1,2,4]);
const digest=f=>crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex');
fs.mkdirSync(path.dirname(out),{recursive:true});fs.mkdirSync(out,{mode:0o700});
const report={schema:1,status:'running',started_at:new Date().toISOString(),plan:{sessions:2,targets:['123','124'],operation:'status',model:'gpt-live-1',interpreter:'jev-1.13.0',synthetic_voice:'macOS Samantha',retry:false},
 git_revision:execFileSync('git',['rev-parse','HEAD'],{cwd:root,encoding:'utf8'}).trim(),offline_report_sha256:digest(gateArg),consumer_sources:verifyConsumer(root,consumer),sources:{},sessions:[]};
for(const f of ['validation/concurrency/live.cjs','validation/task-pilot/server.exs','validation/acceptance/server.exs','validation/task-pilot/outcomes.cjs','validation/task-pilot/replies.cjs','validation/silent-session/collector.exs','validation/interpretation-timeout/collector.exs'])report.sources[f]=digest(path.join(root,f));
const save=()=>fs.writeFileSync(path.join(out,'report.json'),JSON.stringify(report,null,2)+'\n');
const pause=ms=>new Promise(r=>setTimeout(r,ms));
async function until(fn,label,ms=75000){const end=Date.now()+ms;while(Date.now()<end){const v=await fn();if(v)return v;await pause(100);}throw Error('Timed out: '+label);}
let browser,child,url;const clients=[];
async function json(route){const r=await fetch(url+route,{signal:AbortSignal.timeout(4000)});assert(r.ok);return r.json();}
async function stop(){
 for(const c of clients){try{await c.page.locator('#disconnect').click({timeout:1000});}catch(_){}}
 if(url){try{report.cleanup=await until(async()=>{const h=await json('/health');return h.active_sessions===0&&h;},'live cleanup',15000);}catch(e){report.cleanup_error=e.message;report.status='failed';process.exitCode=1;}}
 if(browser)await browser.close();
 if(child&&child.exitCode===null){try{process.kill(-child.pid,'SIGTERM');}catch(_){}await pause(1000);if(child.exitCode===null)try{process.kill(-child.pid,'SIGKILL');}catch(_){}}
}
for(const signal of ['SIGINT','SIGTERM'])process.once(signal,async()=>{report.status='failed';report.error='Interrupted';await stop();save();process.exit(130);});
async function connect(target){
 const context=await browser.newContext(),page=await context.newPage();
 const c={context,page,target,evidence:{events:[],checkpoints:[]}};clients.push(c);
 page.on('pageerror',e=>c.evidence.events.push({type:'pageerror',message:e.message}));
 page.on('websocket',socket=>socket.on('framereceived',({payload})=>{try{const m=JSON.parse(payload.toString());
  if(['transcript','event','status','closed'].includes(m.type)&&c.evidence.events.length<3000)c.evidence.events.push({...m,observed_at_ms:Date.now()});
  if(m.type==='status'&&m.status?.session_id)c.id=m.status.session_id;
 }catch(_){}}));
 await page.route('**/dev/audio/*.wav',route=>route.fulfill({contentType:'audio/wav',path:path.join(out,'audio','status'+target+'.wav')}));
 await page.goto(url);await page.locator('#order-124').waitFor();await page.locator('#recorded-input > summary').click();await page.locator('#diagnostics > summary').click();
 await page.locator('#recorded-connect').click();await until(async()=>/Ready/.test(await page.locator('#connection').innerText()),'live readiness',20000);
 await page.locator('#status').click();await until(()=>c.id,'socket-correlated session ID',5000);
 c.state=async()=>{const s=(await json('/__acceptance/state'))[c.id];assertSessionOpen(s,c.evidence.events);return s;};
 c.wait=(fn,label)=>until(fn,label);return c;
}
(async()=>{
 await prepareAudio(out,{status123:'Check order one hundred twenty three.',status124:'Check order one hundred twenty four.'});
 const port=await new Promise(resolve=>{const s=net.createServer().listen(0,'127.0.0.1',()=>{const p=s.address().port;s.close(()=>resolve(p));});});url=`http://127.0.0.1:${port}`;
 const env={...process.env,MIX_ENV:'dev',ERL_FLAGS:'+sbwt none +sbwtdcpu none +sbwtdio none',ORDER_DESK_TYPESAFE:'1',ORDER_DESK_RECORDED_INPUT:'1',PARLORA_ACCEPTANCE_LIVE:'1',PILOT_DIAGNOSTICS:'1',PILOT_INTERPRETATION_DIAGNOSTICS:'1',PILOT_OUTPUT:out,ORDER_DESK_DATABASE:path.join(out,'fixture.sqlite3'),PORT:String(port)};
 if(process.arch==='arm64')env.RUSTUP_TOOLCHAIN='1.92.0-aarch64-apple-darwin';
 const fd=fs.openSync(path.join(out,'server.log'),'a',0o600);child=spawn('python3',['scripts/with_keychain.py','mix','run',path.join(root,'validation/task-pilot/server.exs')],{cwd:consumer,env,detached:true,stdio:['ignore',fd,fd]});fs.closeSync(fd);
 await until(async()=>{if(child.exitCode!==null)throw Error('Live server exited');try{return (await json('/health')).active_sessions===0;}catch(_){return false;}},'server',120000);
 browser=await chromium.launch({headless:true});report.browser=browser.version();
 await Promise.all(['123','124'].map(connect));assert.equal(new Set(clients.map(c=>c.id)).size,2);assert.equal((await json('/health')).active_sessions,2);
 await pause(3000);
 const initial=await clients[0].page.request.get(url+'/api/orders').then(r=>r.json());
 const playback=await Promise.all(clients.map(async c=>{const start=Date.now();await c.page.locator('#recorded-items').click();await until(async()=> (await c.page.locator('#recorded-state').innerText()).startsWith('items clip finished'),'clip complete',15000);return {session:c.id,start_ms:start,end_ms:Date.now()};}));
 report.playback=playback;assert(Math.max(...playback.map(p=>p.start_ms))<Math.min(...playback.map(p=>p.end_ms)),'Synthetic inputs did not overlap');
 await Promise.all(clients.map(async c=>{
  try{
   const s=await until(async()=>{const s=await c.state();return s.status.interpretation==='settled'&&Object.values(s.status.jobs).some(j=>j['current?']&&j.delivery==='accepted')&&s;},'accepted '+c.target);
   assert.deepEqual(Object.values(s.jobs).map(j=>[j.input.order,j.input.operation]),[[c.target,'status']]);
   await expectReply(c,{since:resultBoundary(c.evidence,s,c.target,'status'),pattern:c.target==='123'?/shipped/i:/out for delivery/i,target:c.target,label:'isolated order '+c.target});
   c.final=await c.state();c.status='passed';
  }catch(e){c.status='failed';c.error=e.message;}
 }));
 const final=await clients[0].page.request.get(url+'/api/orders').then(r=>r.json());assert.deepEqual(final.orders,initial.orders);report.saved_orders_unchanged=true;
 assert(clients.every(c=>c.status==='passed'),'One or more simultaneous calls failed');
 const jobs=clients.map(c=>Object.values(c.final.status.jobs)[0]);
 report.backend_overlap_us=Math.min(...jobs.map(j=>j.completed_at_us))-Math.max(...jobs.map(j=>j.started_at_us));
 assert(report.backend_overlap_us>0,'Concurrent backend execution not observed');
 assert(clients.every(c=>!c.evidence.events.some(e=>e.type==='pageerror')));
 report.status='passed';
})().catch(e=>{report.status='failed';report.error=e.message;process.exitCode=1;}).finally(async()=>{
 for(const c of clients){try{c.evidence.final=(await json('/__acceptance/state'))[c.id];}catch(_){}fs.writeFileSync(path.join(out,'order-'+c.target+'.json'),JSON.stringify(c.evidence,null,2));
  report.sessions.push({target:c.target,id:c.id,status:c.status||'incomplete',error:c.error,evidence:'order-'+c.target+'.json',evidence_sha256:digest(path.join(out,'order-'+c.target+'.json'))});}
 try{fs.writeFileSync(path.join(out,'interpretation.json'),JSON.stringify(await json('/__pilot/interpretation'),null,2));}catch(_){}
 await stop();report.finished_at=new Date().toISOString();save();console.log(JSON.stringify({status:report.status,error:report.error,sessions:report.sessions.map(c=>({target:c.target,status:c.status,error:c.error})),cleanup:report.cleanup}));
});
