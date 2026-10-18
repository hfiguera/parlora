'use strict';
const test=require('node:test');const assert=require('node:assert/strict');
const fs=require('node:fs');const os=require('node:os');const path=require('node:path');
const {spawnSync}=require('node:child_process');
const {comparison}=require('./report.cjs');

test('release plans identify providers and separate explicit Grok reasoning settings',t=>{
  const temp=fs.mkdtempSync(path.join(os.tmpdir(),'parlora-release-plan-'));
  t.after(()=>fs.rmSync(temp,{recursive:true,force:true}));
  const consumer=path.join(temp,'consumer');fs.mkdirSync(consumer);
  const reports=[];
  for(const [name,provider,thinking] of [
    ['gemini','gemini',null],['gemini-legacy-thinking','gemini','high'],['openai','openai',null],
    ['grok-high','grok','high'],['grok-none','grok','none'],['grok-default','grok',null]
  ]) {
    const output=path.join(temp,name),env={...process.env,PARLORA_PROVIDER:provider};
    delete env.GEMINI_THINKING_LEVEL;
    delete env.GROK_REASONING_EFFORT;
    if(provider==='grok' && thinking) env.GROK_REASONING_EFFORT=thinking;
    if(thinking) env.GEMINI_THINKING_LEVEL=thinking;
    const result=spawnSync(process.execPath,[path.join(__dirname,'run.cjs'),consumer,'--output',output],{
      env,encoding:'utf8',timeout:15000
    });
    // An empty existing consumer stops at provenance validation, before any
    // browser, BEAM, native build or paid provider operation can start.
    assert.equal(result.error,undefined);
    assert.equal(result.status,1);
    const report=JSON.parse(fs.readFileSync(path.join(output,'report.json')));
    assert.match(report.error,/Stale consumer source/);
    assert.deepEqual(report.steps,[]);
    const plan=JSON.parse(fs.readFileSync(path.join(output,'plan.json')));
    assert.deepEqual(plan.plan,report.plan);
    assert.equal(report.plan.provider,{gemini:'gemini-3.8-live',openai:'gpt-live-1',grok:'grok-voice-3.0'}[provider]);
    assert.equal(report.plan.thinking_level,null);
    assert.equal(report.plan.reasoning_effort,provider==='grok'?(thinking||'high'):null);
    reports.push(report);
  }
  assert.equal(reports[0].comparison_key,reports[1].comparison_key);
  assert.notEqual(reports[0].comparison_key,reports[2].comparison_key);
  assert.notEqual(reports[3].comparison_key,reports[4].comparison_key);
  assert.notEqual(reports[2].comparison_key,reports[3].comparison_key);
  assert.equal(reports[3].comparison_key,reports[5].comparison_key);
  const live={complete:true,browser:'fixture'};
  assert.equal(comparison({...reports[0],live},{...reports[2],live}).comparable,false);
});
