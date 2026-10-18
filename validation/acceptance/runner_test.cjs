'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const {promisify} = require('node:util');
const execFile = promisify(require('node:child_process').execFile);
for (const fail of [false, true]) test(`runner reports ${fail ? 'failure without retry' : 'six offline passes without credentials'}`, async () => {
  const temp = await fs.mkdtemp(path.join(os.tmpdir(), 'acceptance-runner-test-'));
  try {
    const consumer = path.join(temp, 'consumer'), bin = path.join(temp, 'bin');
    await fs.mkdir(path.join(consumer, 'test'), {recursive: true}); await fs.mkdir(bin);
    await fs.writeFile(path.join(consumer, 'test/acceptance_test.exs'), '');
    await fs.writeFile(path.join(bin, 'mix'), `#!/usr/bin/env node
const fs = require('node:fs');
if (process.env.OPENAI_API_KEY || process.env.TYPESAFE_API_KEY) process.exit(99);
fs.appendFileSync('attempts', 'one\\n');
const cases = Array.from({length: 6}, (_, i) => ({name: 'case ' + i, status: ${fail} && i === 2 ? 'failed' : 'passed'}));
fs.writeFileSync(process.env.PARLORA_ACCEPTANCE_REPORT, JSON.stringify({mode:'deterministic',cases}));
process.exit(${fail ? 2 : 0});
`, {mode: 0o700});
    const output = path.join(temp, 'report');
    let exit = 0;
    try {await execFile(process.execPath, [path.join(__dirname, 'run.cjs'), consumer, '--output', output], {
      env: {...process.env, PATH: bin + path.delimiter + process.env.PATH, OPENAI_API_KEY: 'must-not-reach-offline', TYPESAFE_API_KEY: 'must-not-reach-offline'}, timeout: 15000
    });} catch (e) {exit = e.code;}
    assert.equal(exit, fail ? 1 : 0);
    const report = JSON.parse(await fs.readFile(path.join(output, 'report.json')));
    assert.equal(report.status, fail ? 'failed' : 'passed');
    assert.equal(report.live_requested, false);
    assert.equal(report.checks.live, undefined);
    assert.equal(report.checks.offline.cases.length, 6);
    assert.equal(await fs.readFile(path.join(consumer, 'attempts'), 'utf8'), 'one\n');
  } finally {await fs.rm(temp, {recursive: true, force: true});}
});

const {assertSessionOpen} = require('./assertions.cjs');
test('a provider overflow is a failure, not a successful session cleanup or generic timeout', () => {
  const events = [{event: 'audio_discontinuity', source: 'provider', payload: {cause: 'output_overflow'}}];
  assert.throws(() => assertSessionOpen({closed: true, status: {status: 'closing'}}, events), /provider output_overflow/);
  assert.throws(() => assertSessionOpen({closed: true, status: {status: 'ready'}}, []), /Call ended/);
  assert.doesNotThrow(() => assertSessionOpen({closed: false, status: {status: 'ready'}}, []));
});
