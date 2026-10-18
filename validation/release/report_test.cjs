'use strict';
const test=require('node:test');const assert=require('node:assert/strict');
const fs=require('node:fs');const os=require('node:os');const path=require('node:path');
const {summarizeLive,comparison,distribution}=require('./report.cjs');
function fixture(t,{duplicate=false,incomplete=false}={}) {
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'parlora-release-report-'));t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
  const evidence={events:[{event:'clarification_requested'}],checkpoints:[
    {kind:'input-end',at_ms:100},
    {kind:'reply-check',status:'failed',at_ms:300,wrong_orders:['123'],error:'incorrect-answer'}]};
  fs.writeFileSync(path.join(dir,'case.json'),JSON.stringify(evidence));
  const attempt={name:'example-r1',status:'failed',error:'wrong order',evidence:'case.json'};
  fs.writeFileSync(path.join(dir,'report.json'),JSON.stringify({results:incomplete?[]:duplicate?[attempt,attempt]:[attempt],cleanup:{active_sessions:0}}));
  return dir;
}
test('failures remain failures and are not included as fast successful responses',t=>{
  const report=summarizeLive(fixture(t),['example'],1);
  assert.equal(report.complete,true);assert.equal(report.status,'failed');assert.equal(report.failed,1);
  assert.equal(report.incorrect_answer_flags,1);assert.equal(report.unexpected_clarification_events,1);
  assert.equal(report.reply_check_latency.samples,0);assert.equal(report.reply_check_latency.p50_ms,null);
});
test('missing attempts fail the release and duplicate attempts cannot inflate success',t=>{
  const report=summarizeLive(fixture(t,{incomplete:true}),['example'],1);
  assert.equal(report.complete,false);assert.equal(report.status,'failed');assert.deepEqual(report.missing,['example-r1']);
  assert.throws(()=>summarizeLive(fixture(t,{duplicate:true}),['example'],1),/Duplicate/);
});
test('unlike scoring revisions and incomplete runs cannot be compared as equivalent batches',()=>{
  const live={complete:true,passed:3,incorrect_answer_flags:0,missing_answer_flags:0,unexpected_clarification_events:0,reply_check_latency:{p95_ms:100}};
  assert.equal(comparison({comparison_key:'a',live},{comparison_key:'b',live}).comparable,false);
  assert.equal(comparison({comparison_key:'a',live},{comparison_key:'a',live:{...live,complete:false}}).comparable,false);
  assert.equal(comparison({comparison_key:'a',live},{comparison_key:'a',live:{...live,passed:2}}).passed_delta,1);
  assert.deepEqual(distribution([30,10,20]),{samples:3,p50_ms:20,p95_ms:30,max_ms:30});
});
test('interrupted workers retain completed attempts from the incremental report',t=>{
  const dir=fixture(t);
  const terminal=JSON.parse(fs.readFileSync(path.join(dir,'report.json')));
  fs.writeFileSync(path.join(dir,'live.json'),JSON.stringify({cases:terminal.results}));
  fs.unlinkSync(path.join(dir,'report.json'));
  const summary=summarizeLive(dir,['example'],2);
  assert.equal(summary.completed,1);assert.equal(summary.failed,1);assert.equal(summary.complete,false);
  assert.deepEqual(summary.missing,['example-r2']);
});
