'use strict';
// Credentials arrive over stdin and remain in memory. Never enable browser tracing.
const fs = require('node:fs');
const {chromium} = require('../browser/node_modules/playwright');
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function main(config) {
  const browser = await chromium.launch({channel: 'chrome', headless: true,
    args: ['--autoplay-policy=no-user-gesture-required', '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream']});
  const evidence = {kind: config.channel === 'telnyx' ? 'live_telnyx_smoke' : 'live_twilio_smoke', caller: 'twilio_sdk', errors: []};
  let phase = 'browser_page';
  try {
    const page = await browser.newPage();
    // The SDK and synthetic microphone run only on this private, intercepted origin.
    await page.route('http://localhost:49999/**', route => route.fulfill({contentType: 'text/html', body: '<!doctype html><title>Controlled Twilio caller</title>'}));
    await page.goto('http://localhost:49999/');
    phase = 'load_sdk';
    await page.addScriptTag({path: require('node:path').join(__dirname, 'node_modules/@twilio/voice-sdk/dist/twilio.min.js')});
    phase = 'sdk_connect';
    await page.evaluate(async ({token, nonce}) => {
      const audio = new AudioContext({sampleRate: 48000});
      await audio.resume();
      const destination = audio.createMediaStreamDestination();
      const oscillator = audio.createOscillator(), gain = audio.createGain();
      gain.gain.value = 0;
      oscillator.connect(gain).connect(destination); oscillator.start();
      const device = new Twilio.Device(token, {logLevel: 'silent', codecPreferences: ['pcmu'],
        closeProtection: false, maxCallSignalingTimeoutMs: 0});
      await device.audio.addProcessor({
        createProcessedStream: async () => destination.stream,
        destroyProcessedStream: async () => {}
      });
      window.probe = {device, audio, destination, errors: [], remoteSamples: 0, energySamples: 0, peak: 0, call: null};
      device.on('error', error => probe.errors.push({source: 'device', code: error.code}));
      const call = probe.call = await device.connect({params: {ScenarioToken: nonce}});
      call.on('error', error => probe.errors.push({source: 'call', code: error.code}));
      await new Promise((resolve, reject) => {
        if (call.status() === 'open') return resolve();
        const timer = setTimeout(() => reject(new Error('call_accept_timeout')), 25000);
        call.on('accept', () => {clearTimeout(timer); resolve();});
        call.on('disconnect', () => {clearTimeout(timer); reject(new Error('call_disconnected_before_accept'));});
      });
      let stream;
      for (let count = 0; count < 100; count++) {
        stream = call.getRemoteStream();
        if (stream?.getAudioTracks().length) break;
        await new Promise(resolve => setTimeout(resolve, 50));
      }
      if (!stream) throw new Error('remote_stream_missing');
      const source = audio.createMediaStreamSource(stream);
      const meter = audio.createScriptProcessor(1024, 1, 1);
      meter.onaudioprocess = event => {
        const samples = event.inputBuffer.getChannelData(0);
        probe.remoteSamples += samples.length;
        for (const sample of samples) {
          if (Math.abs(sample) > 0.01) probe.energySamples++;
          probe.peak = Math.max(probe.peak, Math.abs(sample));
        }
        // Numeric evidence only; no recording and no physical speaker output.
        event.outputBuffer.getChannelData(0).fill(0);
      };
      source.connect(meter).connect(audio.destination);
      probe.meter = meter;
    }, {token: config.token, nonce: config.nonce});
    phase = 'greeting';
    const readyDeadline = Date.now() + 25000;
    while (Date.now() < readyDeadline) {
      const sessions = await fetch(config.review + '/__acceptance/state').then(r => r.json());
      if (Object.values(sessions).some(s => !s.closed && s.status.status === 'ready')) break;
      const open = await page.evaluate(() => probe.call.status() === 'open');
      if (!open) throw new Error('call_closed_before_session_ready');
      await pause(200);
    }
    await pause(3000);
    const before = await fetch(config.review + '/__acceptance/state').then(r => r.json());
    evidence.before = before;
    const wav = fs.readFileSync(config.audio).toString('base64');
    await page.evaluate(async encoded => {
      const bytes = Uint8Array.from(atob(encoded), c => c.charCodeAt(0));
      const buffer = await probe.audio.decodeAudioData(bytes.buffer);
      const source = probe.audio.createBufferSource(); source.buffer = buffer;
      source.connect(probe.destination);
      await new Promise(resolve => {source.onended = resolve; source.start();});
    }, wav);
    await pause(16000);
    evidence.after = await fetch(config.review + '/__acceptance/state').then(r => r.json());
    evidence.audio = await page.evaluate(() => ({status: probe.call.status(), remoteSamples: probe.remoteSamples,
      energySamples: probe.energySamples, peak: probe.peak, errors: probe.errors}));
    await page.evaluate(() => {probe.call.disconnect(); probe.device.destroy(); return probe.audio.close();});
    await pause(3000);
    const sessions = Object.values(evidence.after);
    evidence.passed = evidence.audio.status === 'open' && evidence.audio.energySamples > 0 && sessions.some(s => !s.closed && Object.values(s.status.jobs).some(j => j.delivery === 'accepted'));
    evidence.closed = await fetch(config.review + '/__acceptance/state').then(r => r.json());
  } catch (error) {
    // Playwright errors can contain evaluated values; retain only a bounded category.
    const message = String(error.message).split('\n')[0].replaceAll(config.token, '[redacted]').replaceAll(config.nonce, '[redacted]').replace(/eyJ[A-Za-z0-9_.-]+/g, '[redacted]');
    evidence.errors.push({kind: 'caller_failed', name: error.name, phase, message});
  } finally {
    await browser.close();
    fs.writeFileSync(config.report, JSON.stringify(evidence, null, 2) + '\n');
  }
}
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => input += chunk);
process.stdin.on('end', () => main(JSON.parse(input)).catch(() => {process.exitCode = 1;}));
