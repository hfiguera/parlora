'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {spawn,execFileSync} = require('node:child_process');
const {CASES,REPETITIONS,hash,summarizeLive,comparison,markdown} = require('./report.cjs');
const {verifyConsumer} = require('./provenance.cjs');
const root=path.resolve(__dirname,'../..');
const args=process.argv.slice(2);
if(!args.length || args.includes('--help')) {
  console.log('Usage: scripts/release_check.sh CONSUMER --output NEW_DIRECTORY [--live] [--baseline REPORT_JSON] [--interpretation-diagnostics]');
  console.log('Builds CONSUMER if missing; otherwise verifies it matches current source. Offline checks always run. --live adds 7 scenarios × 3 attempts, sequentially, using paid APIs and macOS synthetic speech.');
  process.exit(args.includes('--help')?0:2);
}
const consumer=path.resolve(args.shift());
let output,live=false,baseline,interpretationDiagnostics=false;
while(args.length) {
  const flag=args.shift();
  if(flag==='--live') live=true;
  else if(flag==='--interpretation-diagnostics') interpretationDiagnostics=true;
  else if(flag==='--output' && args.length) output=path.resolve(args.shift());
  else if(flag==='--baseline' && args.length) baseline=path.resolve(args.shift());
  else throw new Error('Unknown or incomplete option: '+flag);
}
if(!output) throw new Error('--output NEW_DIRECTORY is required');
if(interpretationDiagnostics && !live) throw new Error('--interpretation-diagnostics requires --live');
if(live && process.platform!=='darwin') throw new Error('Paid synthetic speech currently requires macOS. Offline checks support Linux.');
const previous=baseline?JSON.parse(fs.readFileSync(baseline)):null;
fs.mkdirSync(output,{mode:0o700});
const providerName=process.env.PARLORA_PROVIDER||'openai';
const models={openai:'gpt-live-1',gemini:'gemini-3.8-live',grok:'grok-voice-3.0'};
if(!models[providerName]) throw new Error('Unknown PARLORA_PROVIDER');
const reasoningEffort=providerName==='grok'?(process.env.GROK_REASONING_EFFORT||'high'):null;
const backendName=process.env.PARLORA_BACKEND||'jido';
if(!['jido','sagents','legion'].includes(backendName)) throw new Error('Unknown PARLORA_BACKEND');
const backend={name:backendName,version:{jido:'2.4.0',sagents:'0.17.1',legion:'0.6.0'}[backendName],
  model:backendName==='jido'?null:(process.env[backendName==='legion'?'LEGION_MODEL':'SAGENTS_MODEL']||'gpt-6-luna'),
  reasoning_effort:backendName==='jido'?null:'none'};
if(reasoningEffort && !['high','none'].includes(reasoningEffort)) throw new Error('Invalid GROK_REASONING_EFFORT');
const report={schema:1,started_at:new Date().toISOString(),status:'running',
  git_revision:execFileSync('git',['rev-parse','HEAD'],{cwd:root,encoding:'utf8'}).trim(),
  git_dirty:!!execFileSync('git',['status','--porcelain'],{cwd:root,encoding:'utf8'}).trim(),
  runtime:{node:process.version,platform:process.platform,arch:process.arch,browser_channel:process.env.BROWSER_CHANNEL || 'chrome'},
  plan:{cases:CASES,repetitions:REPETITIONS,workers:1,live_requested:live,case_deadline_ms:75000,
    interpretation_diagnostics:interpretationDiagnostics,backend,offline_recovery_backend:'jido',provider:models[providerName],thinking_level:null,reasoning_effort:reasoningEffort,interpreter:'jev-1.13.0',speech:'macOS Samantha 165 words/minute'},
  steps:[],sources:{}};
for(const file of ['validation/acceptance/delivery.cjs','validation/release/run.cjs','validation/release/report.cjs','validation/release/provenance.cjs',
  'validation/task-pilot/outcomes.cjs','validation/task-pilot/replies.cjs','validation/task-pilot/scenarios.cjs',
  'validation/task-pilot/run.cjs','validation/task-pilot/server.exs','validation/acceptance/live.cjs',
  'validation/acceptance/server.exs','validation/silent-session/fault_test.cjs','validation/silent-session/fault_server.exs',
  'validation/audio/fixtures/speech.wav','validation/interpretation-timeout/diagnostics_test.exs']) report.sources[file]=hash(path.join(root,file));
report.sources['validation/interpretation-timeout/collector.exs']=hash(path.join(root,'validation/interpretation-timeout/collector.exs'));
const scorerFiles=['validation/acceptance/delivery.cjs','validation/release/report.cjs','validation/task-pilot/outcomes.cjs','validation/task-pilot/replies.cjs',
  'validation/task-pilot/scenarios.cjs','validation/task-pilot/run.cjs','validation/task-pilot/server.exs','validation/acceptance/live.cjs'];
report.comparison_key=crypto.createHash('sha256').update(JSON.stringify({plan:report.plan, runtime:report.runtime,
  scorers:Object.fromEntries(scorerFiles.map(f=>[f,report.sources[f]]))})).digest('hex');
fs.writeFileSync(path.join(output,'plan.json'),JSON.stringify(report,null,2));
const env={...process.env,ERL_FLAGS:process.env.ERL_FLAGS || '+sbwt none +sbwtdcpu none +sbwtdio none'};
if(process.platform==='darwin' && process.arch==='arm64') env.RUSTUP_TOOLCHAIN ||= '1.92.0-aarch64-apple-darwin';
let active;
function save() {
  fs.writeFileSync(path.join(output,'report.json'),JSON.stringify(report,null,2));
  fs.writeFileSync(path.join(output,'report.md'),markdown(report));
}
async function run(name,command,argv,{paid=false,cwd=root,timeout=300000,environment={}}={}) {
  if(report.error) throw new Error(report.error);
  console.log(`Starting ${name}`);
  const log=path.join(output,name+'.log'),fd=fs.openSync(log,'a',0o600);
  const childEnv={...env,...environment};
  if(!paid) {delete childEnv.OPENAI_API_KEY;delete childEnv.GEMINI_API_KEY;delete childEnv.XAI_API_KEY;delete childEnv.TYPESAFE_API_KEY;delete childEnv.SAGENTS_API_KEY;delete childEnv.LEGION_API_KEY;}
  const started=Date.now();
  const result=await new Promise(resolve=>{
    const child=spawn(command,argv,{cwd,env:childEnv,stdio:['ignore',fd,fd]});active=child;
    let timedOut=false,killTimer;
    const timer=setTimeout(()=>{timedOut=true;child.kill('SIGTERM');killTimer=setTimeout(()=>child.kill('SIGKILL'),15000);},timeout);
    child.once('error',e=>{clearTimeout(timer);clearTimeout(killTimer);resolve({code:null,error:e.message});});
    child.once('exit',(code,signal)=>{clearTimeout(timer);clearTimeout(killTimer);resolve({code,signal,error:timedOut?'Process deadline exceeded':null});});
  });
  active=null;fs.closeSync(fd);
  const step={name,status:result.code===0?'passed':'failed',...result,duration_ms:Date.now()-started,log:path.basename(log)};
  // Paid evaluation is represented separately from deterministic steps.
  if(!paid) report.steps.push(step); else report.live_process=step;
  save();console.log(`${step.status}: ${name}`);
  return step;
}
for(const signal of ['SIGINT','SIGTERM']) process.once(signal,()=>{
  report.error='Interrupted by '+signal;report.status='failed';save();
  if(active) active.kill('SIGTERM');
  // Child runners handle their own server process groups and retain partial reports.
  process.exitCode=130;
});
async function main() {
  if(!fs.existsSync(consumer)) {
    const build=await run('consumer-build','scripts/consumer.sh',[consumer],{timeout:1200000});
    if(build.status!=='passed') throw new Error('Standalone consumer build failed');
  }
  report.consumer_sources=verifyConsumer(root,consumer);
  fs.writeFileSync(path.join(output,'plan.json'),JSON.stringify(report,null,2));
  const tests=['validation/task-pilot','validation/release','validation/acceptance'].flatMap(dir=>
    fs.readdirSync(path.join(root,dir)).filter(f=>f.endsWith('_test.cjs')).map(f=>path.join(dir,f)));
  await run('evaluator-tests',process.execPath,['--test',...tests]);
  await run('offline-acceptance','scripts/acceptance.sh',[consumer,'--output',path.join(output,'acceptance')]);
  await run('browser-recovery',process.execPath,['validation/silent-session/fault_test.cjs',consumer,path.join(output,'recovery')]);
  await run('interpretation-diagnostics', 'mix', ['run',path.join(root,'validation/interpretation-timeout/diagnostics_test.exs')],
    {cwd:consumer,environment:{ORDER_DESK_DATABASE:path.join(output,'diagnostic-fixture.sqlite3'),ORDER_DESK_TYPESAFE:'0'}});
  if(report.error) throw new Error(report.error);
  if(report.steps.some(s=>s.status!=='passed')) throw new Error('Offline checks failed; paid evaluation not started');
  const recovery=JSON.parse(fs.readFileSync(path.join(output,'recovery/report.json')));
  if(recovery.cases.length!==3 || recovery.cases.some(c=>c.status!=='passed') || recovery.cleanup.active_sessions!==0)
    throw new Error('Incomplete browser recovery checks');
  report.recovery={passed:3,planned:3,cleanup:recovery.cleanup};
  if(live) {
    const liveDir=path.join(output,'live');
    const step=await run('paid-task-batch',process.execPath,['validation/task-pilot/run.cjs',consumer,liveDir,'--live',
      '--repetitions',String(REPETITIONS),'--cases',CASES.join(','),...(interpretationDiagnostics?['--interpretation-diagnostics']:[])],{paid:true,timeout:2000000});
    if(fs.existsSync(path.join(liveDir,'report.json')) || fs.existsSync(path.join(liveDir,'live.json'))) report.live=summarizeLive(liveDir);
    if(!report.live || step.status!=='passed' || report.live.status!=='passed') report.error ||= 'Paid evaluation contains failures or incomplete attempts';
  }
  if(previous) report.comparison=comparison(report,previous);
}
main().catch(error=>{report.error=error.message;}).finally(()=>{
  report.finished_at=new Date().toISOString();report.status=report.error?'failed':'passed';save();
  console.log(`Release report: ${path.join(output,'report.md')}`);
  if(report.error) {console.error(report.error);process.exitCode=1;}
});
