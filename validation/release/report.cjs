'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const CASES = ['01-cardinal-124','05-items-124','12-correction','14-followup-items','19-spoken-approval','20-browser-confirmation','21-reconnect'];
const REPETITIONS = 3;
const hash = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
function distribution(values) {
  const sorted = values.slice().sort((a,b)=>a-b);
  const at = q => sorted.length ? sorted[Math.ceil(sorted.length*q)-1] : null;
  return {samples: sorted.length, p50_ms: at(.5), p95_ms: at(.95), max_ms: at(1)};
}
function summarizeLive(directory, planned = CASES, repetitions = REPETITIONS) {
  const terminal=path.join(directory,'report.json'),progress=path.join(directory,'live.json');
  const source = fs.existsSync(terminal)?JSON.parse(fs.readFileSync(terminal)):{error:'No terminal worker report',results:[]};
  if(!source.results.length && fs.existsSync(progress)) source.results=JSON.parse(fs.readFileSync(progress)).cases;
  const expected = planned.flatMap(id=>Array.from({length:repetitions},(_,i)=>`${id}-r${i+1}`));
  const seen = new Set(), trials = [], latencies = [];
  for (const result of source.results) {
    if(seen.has(result.name) || !expected.includes(result.name)) throw new Error('Duplicate or unplanned trial: '+result.name);
    seen.add(result.name);
    const file = path.join(directory,result.evidence);
    const evidence = JSON.parse(fs.readFileSync(file));
    const checks = evidence.checkpoints.filter(c=>c.kind==='reply-check');
    const clarifications = evidence.events.filter(e=>e.event==='clarification_requested').length;
    const delay = [];
    for(const check of checks.filter(c=>c.status==='passed')) {
      const input = evidence.checkpoints.filter(c=>['input-end','browser-confirmation'].includes(c.kind) && c.at_ms<=check.at_ms).at(-1);
      if(input) delay.push(check.at_ms-input.at_ms);
    }
    latencies.push(...delay);
    trials.push({name:result.name,status:result.status,error:result.error || null,evidence_sha256:hash(file),
      duration_ms:result.duration_ms,reply_checks:checks.length,
      passed_reply_checks:checks.filter(c=>c.status==='passed').length,
      incorrect_answer_flags:checks.filter(c=>c.wrong_orders?.length || c.contradiction).length,
      missing_answer_flags:checks.filter(c=>c.status==='failed' && c.error?.includes('[missing-answer]')).length,
      clarifications,unexpected_clarifications:result.name.startsWith('19-')?0:clarifications,
      reply_check_latency_ms:delay});
  }
  const missing = expected.filter(name=>!seen.has(name));
  const complete = !source.error && !missing.length && source.cleanup?.active_sessions===0;
  return {status:complete && trials.every(t=>t.status==='passed')?'passed':'failed',
    complete, browser:source.browser, planned:expected.length, completed:trials.length, passed:trials.filter(t=>t.status==='passed').length,
    failed:trials.filter(t=>t.status!=='passed').length,missing,worker_error:source.error || null,
    incorrect_answer_flags:trials.reduce((n,t)=>n+t.incorrect_answer_flags,0),
    missing_answer_flags:trials.reduce((n,t)=>n+t.missing_answer_flags,0),
    clarification_events:trials.reduce((n,t)=>n+t.clarifications,0),
    unexpected_clarification_events:trials.reduce((n,t)=>n+t.unexpected_clarifications,0),
    reply_check_latency:distribution(latencies),cleanup:source.cleanup,trials,
    report_sha256:fs.existsSync(terminal)?hash(terminal):null,progress_sha256:fs.existsSync(progress)?hash(progress):null};
}
function comparison(current, baseline) {
  if(!current.live || !baseline.live || current.comparison_key!==baseline.comparison_key || JSON.stringify(current.live.browser)!==JSON.stringify(baseline.live.browser) || !current.live.complete || !baseline.live.complete)
    return {comparable:false,reason:'Requires complete batches with the same scenario/scorer hashes, models, browser, platform, repetitions and concurrency.'};
  return {comparable:true, note:'Descriptive differences between small synthetic batches; not statistical significance.',
    passed_delta:current.live.passed-baseline.live.passed,
    incorrect_answer_flags_delta:current.live.incorrect_answer_flags-baseline.live.incorrect_answer_flags,
    missing_answer_flags_delta:current.live.missing_answer_flags-baseline.live.missing_answer_flags,
    unexpected_clarification_events_delta:current.live.unexpected_clarification_events-baseline.live.unexpected_clarification_events,
    reply_check_p95_delta_ms:current.live.reply_check_latency.p95_ms===null || baseline.live.reply_check_latency.p95_ms===null?null:
      current.live.reply_check_latency.p95_ms-baseline.live.reply_check_latency.p95_ms};
}
function markdown(report) {
  const lines = [`# Parlora browser release check: ${report.status}`,'',
    `Source: ${report.git_revision}${report.git_dirty?' + uncommitted changes (hashes recorded)':''}.`, '',
    '## Offline checks','',...report.steps.map(s=>`- ${s.status}: ${s.name}${s.error?' — '+s.error:''}`),''];
  if(report.live) {
    const l=report.live;
    lines.push('## Paid model evaluation','',`${l.passed}/${l.planned} scheduled attempts passed; ${l.failed} failed; ${l.missing.length} missing.`,
      `Complete batch: ${l.complete}. Incorrect-answer flags: ${l.incorrect_answer_flags}; missing-answer flags: ${l.missing_answer_flags}.`,
      `Application clarifications: ${l.clarification_events}; outside the permitted scenarios: ${l.unexpected_clarification_events}.`,
      `Reply-check latency: ${l.reply_check_latency.samples} observations, p50 ${l.reply_check_latency.p50_ms} ms, p95 ${l.reply_check_latency.p95_ms} ms.`,
      '', '| Attempt | Outcome | Reason |','| --- | --- | --- |',
      ...l.trials.map(t=>`| ${t.name} | ${t.status} | ${(t.error || '').replaceAll('|','/').replaceAll('\n',' ')} |`),'');
  } else lines.push('Paid model evaluation: not run. An offline pass does not establish model response quality.','');
  if(report.comparison) lines.push('## Baseline comparison','', '```json',JSON.stringify(report.comparison,null,2),'```','');
  if(report.error) lines.push('Error: '+report.error,'');
  lines.push('## Interpretation','',
    'Synthetic speech and bounded caption checks only. No human listening, accent coverage, phone-channel readiness, or production success-rate claim.',
    'Latency is from fixture playback completion (or browser confirmation) to the successful reply check, including its one-second quiet observation. It is not first-audio or human-perceived latency. Failed waits are reported separately, not included as fast responses.',
    'Incorrect/missing-answer counts are observed rule-based flags, not an exhaustive semantic audit. A backend failure can prevent reply assessment entirely. Recovery fault checks use a local protocol peer; paid reconnect trials are separate.',
    'All scheduled attempts are retained. No retry replaces a failure. A comparison is descriptive and cannot establish significance.','');
  return lines.join('\n');
}
module.exports={CASES,REPETITIONS,hash,distribution,summarizeLive,comparison,markdown};
