'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const {spawn} = require('node:child_process');
const net = require('node:net');
const root = path.resolve(__dirname, '../..');
const args = process.argv.slice(2);
if (!args[0] || args.includes('--help')) {
  console.log('Usage: scripts/acceptance.sh /absolute/consumer [--live] [--output NEW_DIRECTORY]');
  console.log('Offline: six deterministic application scenarios. --live adds six paid browser calls (one includes reconnect).');
  process.exit(args.includes('--help') ? 0 : 2);
}
const consumer = path.resolve(args.shift());
let live = false, output;
while (args.length) {
  const flag = args.shift();
  if (flag === '--live') live = true;
  else if (flag === '--output' && args.length) output = path.resolve(args.shift());
  else throw new Error(`Unknown or incomplete option: ${flag}`);
}
if (!fs.existsSync(path.join(consumer, 'test/acceptance_test.exs'))) throw new Error('Consumer lacks acceptance tests; regenerate it with scripts/consumer.sh from examples/order_desk.');
if (output) fs.mkdirSync(output, {recursive: false, mode: 0o700});
else output = fs.mkdtempSync(path.join(os.tmpdir(), 'parlora-acceptance-'));
fs.chmodSync(output, 0o700);
const report = {runtime: {node: process.version, platform: process.platform, arch: process.arch}, started_at: new Date().toISOString(), live_requested: live, output, checks: {}};
const active = new Set();
let closeLive = async () => {};
const env = {...process.env, ERL_FLAGS: process.env.ERL_FLAGS || '+sbwt none +sbwtdcpu none +sbwtdio none'};
if (process.platform === 'darwin' && process.arch === 'arm64') env.RUSTUP_TOOLCHAIN ||= '1.92.0-aarch64-apple-darwin';
function start(command, argv, childEnv, log) {
  const fd = fs.openSync(path.join(output, log), 'a', 0o600);
  const child = spawn(command, argv, {cwd: consumer, env: childEnv, detached: true, stdio: ['ignore', fd, fd]});
  fs.closeSync(fd); active.add(child);
  child.done = new Promise((resolve, reject) => {child.once('error', reject); child.once('exit', (code, signal) => {active.delete(child); resolve({code, signal});});});
  return child;
}
async function stop(child) {
  if (!active.has(child)) return;
  try {process.kill(-child.pid, 'SIGTERM');} catch (_) {}
  const exited = await Promise.race([child.done.then(() => true), new Promise(r => setTimeout(() => r(false), 5000))]);
  if (!exited) {try {process.kill(-child.pid, 'SIGKILL');} catch (_) {} await child.done;}
}
async function bounded(child, ms) {
  let timer;
  try {return await Promise.race([child.done, new Promise((_, reject) => {timer = setTimeout(() => reject(new Error('Process deadline exceeded')), ms);})]);}
  finally {clearTimeout(timer); await stop(child);}
}
async function freePort() {
  const server = net.createServer();
  await new Promise((resolve, reject) => {server.once('error', reject); server.listen(0, '127.0.0.1', resolve);});
  const port = server.address().port;
  await new Promise(resolve => server.close(resolve)); return port;
}
async function main() {
  console.log(`Acceptance report: ${output}`);
  const offline = start('mix', ['test', 'test/acceptance_test.exs', '--seed', '42'], {
    ...env, MIX_ENV: 'test', OPENAI_API_KEY: '', TYPESAFE_API_KEY: '', ORDER_DESK_TYPESAFE: '',
    ORDER_DESK_DATABASE: path.join(output, 'offline.sqlite3'),
    PARLORA_ACCEPTANCE_REPORT: path.join(output, 'offline.json')
  }, 'offline.log');
  const result = await bounded(offline, 180000);
  const offlineReport = JSON.parse(fs.readFileSync(path.join(output, 'offline.json')));
  report.checks.offline = offlineReport;
  if (result.code !== 0 || offlineReport.cases.length !== 6 || offlineReport.cases.some(c => c.status !== 'passed')) throw new Error('Deterministic acceptance failed; see offline.log');
  console.log('Deterministic: 6/6 passed');
  if (live) {
    if (process.platform !== 'darwin') throw new Error('Live runner currently requires macOS say for synthetic speech; deterministic mode supports Linux.');
    if (!fs.existsSync(path.join(root, 'validation/browser/node_modules/playwright')))
      throw new Error('Install browser dependencies first: npm ci --prefix validation/browser');
    const liveRunner = require('./live.cjs');
    const {runLive, prepareAudio} = liveRunner; closeLive = liveRunner.closeLive;
    await prepareAudio(output);
    const port = await freePort();
    const childEnv = {...env, MIX_ENV: 'dev', ORDER_DESK_RECORDED_INPUT: '1', ORDER_DESK_TYPESAFE: '1',
      PARLORA_ACCEPTANCE_LIVE: '1', ORDER_DESK_DATABASE: path.join(output, 'live.sqlite3'), PORT: String(port)};
    const mixArgs = ['mix', 'run', path.join(__dirname, 'server.exs')];
    const server = childEnv.OPENAI_API_KEY && childEnv.TYPESAFE_API_KEY
      ? start(mixArgs[0], mixArgs.slice(1), childEnv, 'server.log')
      : start('python3', ['scripts/with_keychain.py', ...mixArgs], childEnv, 'server.log');
    try {report.checks.live = await runLive(`http://127.0.0.1:${port}`, output);}
    finally {await stop(server);}
    if (report.checks.live.cases.some(c => c.status !== 'passed')) throw new Error('Live acceptance contains failures; see report.json and case evidence');
  }
}
let interrupted = false;
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, async () => {
  if (interrupted) return; interrupted = true;
  report.error = `Interrupted by ${signal}`; await finish(); process.exit(130);
});
async function finish() {
  await closeLive();
  await Promise.all([...active].map(stop));
  report.finished_at = new Date().toISOString();
  report.status = report.error ? 'failed' : 'passed';
  fs.writeFileSync(path.join(output, 'report.json'), JSON.stringify(report, null, 2));
  const lines = [`# Parlora acceptance: ${report.status}`, '', ...Object.entries(report.checks).flatMap(([mode, run]) =>
    [`## ${mode}`, '', ...(run.cases || []).map(c => `- ${c.status}: ${c.name}`), '']), ...(report.error ? [report.error] : [])];
  fs.writeFileSync(path.join(output, 'report.md'), lines.join('\n'));
}
main().catch(error => {report.error = error.message; process.exitCode = 1; console.error(error.message);}).finally(finish);
