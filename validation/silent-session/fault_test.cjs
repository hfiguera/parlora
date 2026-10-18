'use strict';
const assert=require('node:assert/strict');
const fs=require('node:fs');const path=require('node:path');const net=require('node:net');const {spawn}=require('node:child_process');
const {runLive,closeLive}=require('../acceptance/live.cjs');
const consumer=path.resolve(process.argv[2]);const output=path.resolve(process.argv[3]);
fs.mkdirSync(output,{mode:0o700});
let child;
async function stop() {
 await closeLive();
 if(child && child.exitCode===null) {
  try {process.kill(-child.pid,'SIGTERM');} catch(_) {}
  await new Promise(r=>setTimeout(r,1000));
  if(child.exitCode===null) {try {process.kill(-child.pid,'SIGKILL');} catch(_) {}}
 }
}
for(const signal of ['SIGINT','SIGTERM']) process.once(signal,async()=>{await stop();process.exit(130);});
(async()=>{
 // The local peer scripts the captions; this fixture only needs nonzero PCM.
 // Reuse committed synthetic audio so Linux CI needs no speech service.
 fs.mkdirSync(path.join(output,'audio'));
 for(const name of ['status124','status123']) fs.copyFileSync(path.join(__dirname,'../audio/fixtures/speech.wav'),path.join(output,'audio',name+'.wav'));
 const port=await new Promise(resolve=>{const s=net.createServer().listen(0,'127.0.0.1',()=>{const p=s.address().port;s.close(()=>resolve(p));});});
 const fd=fs.openSync(path.join(output,'server.log'),'a',0o600);
 const env={...process.env,MIX_ENV:'dev',ERL_FLAGS:'+sbwt none +sbwtdcpu none +sbwtdio none',ORDER_DESK_RECORDED_INPUT:'1',ORDER_DESK_TYPESAFE:'0',ORDER_DESK_DATABASE:path.join(output,'fixture.sqlite3'),PILOT_OUTPUT:output,PORT:String(port)};
 if(process.platform==='darwin' && process.arch==='arm64') env.RUSTUP_TOOLCHAIN ||= '1.92.0-aarch64-apple-darwin';
 delete env.OPENAI_API_KEY; delete env.TYPESAFE_API_KEY;
 child=spawn('mix',['run',path.join(__dirname,'fault_server.exs')],{cwd:consumer,env,detached:true,stdio:['ignore',fd,fd]});fs.closeSync(fd);fs.writeFileSync(path.join(output,'server-pid.json'),JSON.stringify({pid:child.pid}));
 const url=`http://127.0.0.1:${port}`;
 for(let n=0;n<240;n++){try{if((await fetch(url+'/health')).ok)break;}catch(_){} if(child.exitCode!==null)throw new Error('Fault server exited');await new Promise(r=>setTimeout(r,500));}
 const result=await runLive(url,output,{caseTimeoutMs:30000,captureMedia:true,validateCase:async()=>{},scenarios:[
  ['silent-provider-closes',async h=>{
   const before=await h.dashboard();await h.connect({items:'status124'});
   await h.wait(async()=>/voice service stopped responding/.test(await h.page.locator('#connection').innerText()),'visible timeout recovery');
   assert(await h.page.locator('#recorded-connect').isEnabled());
   assert(await h.page.locator('#connect').isEnabled());
   assert(await h.page.locator('#disconnect').isDisabled());
   assert(h.evidence.events.some(e=>e.event==='failed'&&e.payload.cause==='command_ack_timeout'));
   assert.equal(Object.keys((await h.state(true)).jobs).length,0);
   assert.deepEqual((await h.dashboard()).orders,before.orders);
  }],
  ['acknowledged-but-silent-closes',async h=>{
   const before=await h.dashboard();await h.connect({items:'status124'});
   await h.wait(async()=>/voice service stopped responding/.test(await h.page.locator('#connection').innerText()),'visible progress timeout recovery');
   const stopped=await h.state(true);
   assert(stopped.events.some(e=>e.type==='context_acknowledged'));
   const failure=stopped.events.find(e=>e.type==='failed'&&e.payload.cause==='progress_timeout');
   assert(failure.payload.health.input_forwarded.bytes>0);
   assert.equal(failure.payload.health.expectation.status,'timed_out');
   assert(h.evidence.events.some(e=>e.event==='failed'&&e.payload.cause==='progress_timeout'));
   assert(!h.evidence.events.some(e=>e.event==='failed'&&e.payload.cause==='command_ack_timeout'));
   assert(await h.page.locator('#recorded-connect').isEnabled());
   assert(await h.page.locator('#connect').isEnabled());
   assert(await h.page.locator('#disconnect').isDisabled());
   assert.equal(Object.keys((await h.state(true)).jobs).length,0);
   assert.deepEqual((await h.dashboard()).orders,before.orders);
  }],
  ['fresh-session-works',async h=>{
   const before=await h.dashboard();await h.connect({items:'status124'});await h.play('items');
   const state=await h.accepted('124','status');assert.equal(Object.keys(state.jobs).length,1);
   await h.caption(/out for delivery/i);
   assert.deepEqual((await h.dashboard()).orders,before.orders);
  }]
 ]});
 const cleanup=await (await fetch(url+'/health')).json();assert.equal(cleanup.active_sessions,0);
 fs.writeFileSync(path.join(output,'report.json'),JSON.stringify({fixture:'Local protocol fault injection, not live model accuracy',...result,cleanup},null,2));
 if(result.cases.some(c=>c.status!=='passed'))process.exitCode=1;
})().catch(e=>{console.error(e.message);process.exitCode=1;}).finally(stop);
