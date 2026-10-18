'use strict';
const fs = require('node:fs');
async function connect(browser, config) {
  const page = await browser.newPage();
    await page.route('http://localhost:49999/**', route => route.fulfill({contentType: 'text/html', body: '<!doctype html><title>Controlled Twilio caller</title>'}));
    await page.goto('http://localhost:49999/');
    await page.addScriptTag({path: require('node:path').join(__dirname, 'node_modules/@twilio/voice-sdk/dist/twilio.min.js')});
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
      window.probe = {device, audio, destination, errors: [], remoteSamples: 0, energySamples: 0, lastEnergyAt: null, peak: 0, call: null};
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
        const beforeEnergy = probe.energySamples;
        for (const sample of samples) {
          if (Math.abs(sample) > 0.01) probe.energySamples++;
          probe.peak = Math.max(probe.peak, Math.abs(sample));
        }
        if (probe.energySamples > beforeEnergy) probe.lastEnergyAt = performance.now();
        // Numeric evidence only; no recording and no physical speaker output.
        event.outputBuffer.getChannelData(0).fill(0);
      };
      source.connect(meter).connect(audio.destination);
      probe.meter = meter;
    }, {token: config.token, nonce: config.nonce});

  return page;
}
async function play(page, file) {
    const wav = fs.readFileSync(file).toString('base64');
    await page.evaluate(async encoded => {
      const bytes = Uint8Array.from(atob(encoded), c => c.charCodeAt(0));
      const buffer = await probe.audio.decodeAudioData(bytes.buffer);
      const source = probe.audio.createBufferSource(); source.buffer = buffer;
      source.connect(probe.destination);
      await new Promise(resolve => {source.onended = resolve; source.start();});
    }, wav);
}
async function metrics(page) { return page.evaluate(() => ({status: probe.call.status(), remoteSamples: probe.remoteSamples, energySamples: probe.energySamples, peak: probe.peak, lastEnergyAgeMs: probe.lastEnergyAt === null ? null : performance.now() - probe.lastEnergyAt, errors: probe.errors})); }
async function disconnect(page) { await page.evaluate(() => {probe.call.disconnect(); probe.device.destroy(); return probe.audio.close();}); await page.close(); }
module.exports = {connect, play, metrics, disconnect};
