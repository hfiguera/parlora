'use strict';
const fs = require('node:fs');
const path = require('node:path');
const net = require('node:net');
const crypto = require('node:crypto');
const {spawn, execFileSync} = require('node:child_process');
const {runLive, prepareAudio, closeLive} = require('../acceptance/live.cjs');
const assert = require('node:assert/strict');
const assertOrdersUnchanged = (before,after) => assert.deepEqual(after,before,'[database-change] Saved orders changed without explicit browser confirmation');
const {definitions, phrases} = require('./scenarios.cjs');
const args = process.argv.slice(2);
const consumer = path.resolve(args.shift() || '');
const output = path.resolve(args.shift() || '');
if (!args.includes('--live') || !fs.existsSync(path.join(consumer,'mix.exs')) || output === process.cwd()) {
  throw new Error('Usage: node validation/task-pilot/run.cjs CONSUMER NEW_OUTPUT --live [--repetitions N] [--cases ID,ID]');
}
const value = (key, fallback) => args.includes(key) ? args[args.indexOf(key)+1] : fallback;
const diagnostics = args.includes('--diagnostics');
const interpretationDiagnostics = args.includes('--interpretation-diagnostics');
const repetitions = Number(value('--repetitions','3'));
if (!Number.isInteger(repetitions) || repetitions < 1 || repetitions > 3) throw new Error('Repetitions must be 1..3');
const firstRepetition = Number(value('--repetition-start','1'));
if (!Number.isInteger(firstRepetition) || firstRepetition < 1 || firstRepetition + repetitions > 4) throw new Error('Repetition range must stay within 1..3');
const selected = value('--cases','').split(',').filter(Boolean);
const cases = definitions.filter(d => !selected.length || selected.includes(d.id));
if (!cases.length || selected.some(id => !definitions.some(d => d.id === id))) throw new Error('Unknown case selection');
fs.mkdirSync(output, {mode:0o700});
const digest = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const provider=process.env.PARLORA_PROVIDER||'openai';
const models={openai:'gpt-live-1',gemini:'gemini-3.8-live',grok:'grok-voice-3.0'};
if(!models[provider]) throw new Error('Unknown PARLORA_PROVIDER');
const model=models[provider];
const reasoningEffort=provider==='grok'?(process.env.GROK_REASONING_EFFORT||'high'):null;
const backendName=process.env.PARLORA_BACKEND||'jido';
if(!['jido','sagents','legion'].includes(backendName)) throw new Error('Unknown PARLORA_BACKEND');
const backend={name:backendName,version:{jido:'2.4.0',sagents:'0.17.1',legion:'0.6.0'}[backendName],
  model:backendName==='jido'?null:(process.env[backendName==='legion'?'LEGION_MODEL':'SAGENTS_MODEL']||'gpt-6-luna'),
  reasoning_effort:backendName==='jido'?null:'none'};
if(reasoningEffort && !['high','none'].includes(reasoningEffort)) throw new Error('Invalid GROK_REASONING_EFFORT');
const report = {backend,reasoning_effort:reasoningEffort, diagnostics, interpretation_diagnostics:interpretationDiagnostics, slow_correction:process.env.PILOT_SLOW_CORRECTION==='1', started_at:new Date().toISOString(), model, thinking_level:null, interpretation_model:'jev-1.13.0',
  speech:'macOS Samantha, 165 words/minute; synthetic speech, no human microphone', repetitions, first_repetition:firstRepetition,
  git_revision:execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim(),
  git_dirty:!!execFileSync('git',['status','--porcelain','--untracked-files=normal'],{encoding:'utf8'}).trim(),
  sources:Object.fromEntries(['run.cjs','scenarios.cjs','server.exs','replies.cjs','outcomes.cjs'].map(f => [f,digest(path.join(__dirname,f))])),
  cases:cases.map(({id,goal,type}) => ({id,goal,type})), resets:[], results:[],
  limitations:['Small synthetic-speech pilot, not human/accent or production success-rate certification.',
    'Assistant replies checked from provider captions, not human listening or acoustic playback verification.',
    'Scheduled repetitions are separate attempts; failures remain failures, not replaced by retries.']};
for (const f of ['run.cjs','scenarios.cjs','server.exs','replies.cjs','outcomes.cjs']) fs.copyFileSync(path.join(__dirname,f),path.join(output,f));
fs.copyFileSync(path.join(__dirname,'../acceptance/live.cjs'),path.join(output,'live.cjs'));
report.sources['live.cjs']=digest(path.join(output,'live.cjs'));
report.sources['delivery.cjs']=digest(path.join(__dirname,'../acceptance/delivery.cjs'));
fs.copyFileSync(path.join(__dirname,'../acceptance/delivery.cjs'),path.join(output,'delivery.cjs'));
fs.copyFileSync(path.join(__dirname,'../acceptance/server.exs'),path.join(output,'acceptance-server.exs'));
report.sources['acceptance-server.exs']=digest(path.join(output,'acceptance-server.exs'));
if(diagnostics) {
  fs.copyFileSync(path.join(__dirname,'../silent-session/collector.exs'),path.join(output,'collector.exs'));
  report.sources['collector.exs']=digest(path.join(output,'collector.exs'));
}
if(interpretationDiagnostics) {
  fs.copyFileSync(path.join(__dirname,'../interpretation-timeout/collector.exs'),path.join(output,'interpretation-collector.exs'));
  report.sources['interpretation-collector.exs']=digest(path.join(output,'interpretation-collector.exs'));
}
// The standalone app can contain an uncommitted fix; HEAD alone is insufficient.
report.consumer_sources={};
for (const area of ['lib','config','priv/browser','vendor/parlora/lib']) {
  for (const relative of fs.readdirSync(path.join(consumer,area),{recursive:true})) {
    const source=path.join(consumer,area,relative);
    if(fs.statSync(source).isFile()) report.consumer_sources[area+'/'+relative]=digest(source);
  }
}
for (const file of ['mix.exs','mix.lock','vendor/parlora/mix.exs','vendor/parlora/mix.lock'])
  report.consumer_sources[file]=digest(path.join(consumer,file));
fs.copyFileSync(path.join(consumer,'lib/order_desk/interpretation.ex'),path.join(output,'interpretation.ex'));
fs.writeFileSync(path.join(output,'plan.json'),JSON.stringify(report,null,2));
let child;
async function stop() {
  await closeLive();
  if (child && child.exitCode === null) {
    try {process.kill(-child.pid,'SIGTERM');} catch (_) {}
    await Promise.race([new Promise(resolve => child.once('exit',resolve)),new Promise(resolve => setTimeout(resolve,5000))]);
    if (child.exitCode === null) {try {process.kill(-child.pid,'SIGKILL');} catch (_) {}}
  }
}
function retainProgress() {
  const progress=path.join(output,'live.json');
  if(!report.results.length && fs.existsSync(progress)) report.results=JSON.parse(fs.readFileSync(progress)).cases;
}
for (const signal of ['SIGINT','SIGTERM']) process.once(signal, async () => {
  report.status='failed'; report.error='Interrupted by '+signal;
  await stop(); retainProgress(); report.finished_at=new Date().toISOString();
  fs.writeFileSync(path.join(output,'report.json'),JSON.stringify(report,null,2));
  process.exit(130);
});
async function main() {
  await prepareAudio(output,phrases);
  report.audio_sha256=Object.fromEntries(fs.readdirSync(path.join(output,'audio')).map(f => [f,digest(path.join(output,'audio',f))]));
  const port = await new Promise(resolve => {const s=net.createServer().listen(0,'127.0.0.1',()=>{const p=s.address().port;s.close(()=>resolve(p));});});
  const env={...process.env,MIX_ENV:'dev',ERL_FLAGS:'+sbwt none +sbwtdcpu none +sbwtdio none',
    RUSTUP_TOOLCHAIN:'1.92.0-aarch64-apple-darwin',ORDER_DESK_RECORDED_INPUT:'1',ORDER_DESK_TYPESAFE:'1',
    PARLORA_ACCEPTANCE_LIVE:'1',ORDER_DESK_DATABASE:path.join(output,'initial.sqlite3'),PILOT_OUTPUT:output,PILOT_DIAGNOSTICS:diagnostics?'1':'0',PILOT_INTERPRETATION_DIAGNOSTICS:interpretationDiagnostics?'1':'0',PORT:String(port)};
  const fd=fs.openSync(path.join(output,'server.log'),'a',0o600);
  child=spawn('python3',['scripts/with_keychain.py','mix','run',path.join(__dirname,'server.exs')],{cwd:consumer,env,detached:true,stdio:['ignore',fd,fd]});
  fs.closeSync(fd);
  const scheduled=[];
  for(let r=firstRepetition;r<firstRepetition+repetitions;r++) for(const d of cases) scheduled.push([`${d.id}-r${r}`,d.run]);
  const start = Date.now();
  // Development-mode compilation in a fresh standalone installation can take a minute.
  while (Date.now()-start<120000) {
    try {const res=await fetch(`http://127.0.0.1:${port}/health`,{signal:AbortSignal.timeout(1000)});if(res.ok) break;} catch (_) {}
    if(child.exitCode!==null) throw new Error('Pilot server exited; see server.log');
    await new Promise(resolve=>setTimeout(resolve,500));
  }
  const live = await runLive(`http://127.0.0.1:${port}`,output,{
    scenarios:scheduled,caseTimeoutMs:75000,captureMedia:diagnostics,baseline:true,
    async beforeCase(url,name) {
      const r=await fetch(url+'/__pilot/reset',{method:'POST',signal:AbortSignal.timeout(5000)});
      if(!r.ok) throw new Error('Fresh-case reset failed');
      report.resets.push({name,...await r.json()});
    },
    async validateCase(h,name) {
      const baseline=h.evidence.checkpoints.find(c=>c.kind==='baseline');
      if (!['20-','22-','27-'].some(prefix=>name.startsWith(prefix))) assertOrdersUnchanged(baseline.dashboard.orders,(await h.dashboard()).orders);
      const allowed=name.startsWith('09-')||name.startsWith('10-')||name.startsWith('19-')||name.startsWith('25-');
      if (!allowed && h.evidence.events.some(e=>e.event==='clarification_requested')) throw new Error('Unexpected application clarification for a clear request');
      const s=await h.state();
      const expectedReads={
        '01-cardinal-124':['124:status'], '05-items-124':['124:items'],
        '12-correction':['123:status','124:status'], '14-followup-items':['124:status','124:items'],
        '21-reconnect':['124:items']
      }[name.replace(/-r[1-3]$/,'')];
      if(expectedReads) assert.deepEqual(Object.values(s.jobs).map(j=>`${j.input.order}:${j.input.operation}`).sort(),expectedReads.sort(),
        '[backend-action] Unexpected or duplicate final read work');
      if(s && !Object.values(s.status.delegations).every(d=>['claimed','cancelled'].includes(d.status))) throw new Error('Unclaimed delegation at outcome');
    },
    async afterCase(h,url) {
      if(!diagnostics || !h.sessionId()) return;
      const deadline=Date.now()+3000;
      while(Date.now()<deadline) {
        const response=await fetch(url+'/__pilot/provider-diagnostics/'+encodeURIComponent(h.sessionId()),{signal:AbortSignal.timeout(1000)});
        if(!response.ok) throw new Error('Diagnostics unavailable');
        const data=await response.json();
        if(data) {h.evidence.provider_diagnostics=data;return;}
        await h.pause(100);
      }
      throw new Error('Provider diagnostics missing after closure');
    },
    async captureCase(h,url) {
      h.evidence.interpretation=await (await fetch(url+'/__pilot/interpretation',{signal:AbortSignal.timeout(3000)})).json();
    }
  });
  report.results=live.cases; report.browser=live.browser;
  report.cleanup=await (await fetch(`http://127.0.0.1:${port}/health`,{signal:AbortSignal.timeout(3000)})).json();
  report.status=live.cases.every(c=>c.status==='passed')?'passed':'failed';
  if(report.cleanup.active_sessions !== 0) {report.status='failed';report.error='Session cleanup incomplete';}
  if(report.status==='failed') process.exitCode=1;
}
main().catch(e=>{report.status='failed';report.error=e.message;process.exitCode=1;console.error(e.message);}).finally(async()=>{
  await stop(); retainProgress(); report.finished_at=new Date().toISOString();
  fs.writeFileSync(path.join(output,'report.json'),JSON.stringify(report,null,2));
  console.log('Pilot evidence: '+output);
});
