'use strict';
(() => {
  const el = id => document.getElementById(id);
  const clips = ['draft', 'refuse', 'items', 'package', 'correct', 'interrupt'];
  let context, destination, silence, source, controller;
  let buffers = {}, connected = false, ready = false, muted = false, generation = 0;
  const status = text => { el('recorded-state').textContent = text; };
  const buttons = () => {
    el('recorded-connect').disabled = connected;
    for (const clip of clips) el(`recorded-${clip}`).disabled = !ready || muted || !!source;
    el('recorded-stop').disabled = !source;
  };
  const stop = () => {
    if (!source) return;
    const old = source; source = null;
    old.onended = null;
    try { old.stop(); } catch (_) { /* A canceled resume may not have started the node yet. */ }
    old.disconnect();
    buttons();
  };
  const close = () => {
    generation++;
    controller?.abort(); controller = null;
    stop();
    if (silence) { silence.stop(); silence.disconnect(); silence = null; }
    destination?.stream.getTracks().forEach(track => track.stop()); destination = null;
    const old = context; context = null;
    old?.close().catch(() => {});
    buffers = {}; ready = false; muted = false; connected = false;
    status('Recorded input is off.'); buttons();
  };
  const open = async () => {
    close();
    const current = generation;
    connected = true; buttons(); status('Loading synthetic speech clips…');
    const audio = new AudioContext({sampleRate: 48000});
    context = audio;
    controller = new AbortController();
    const signal = AbortSignal.any([controller.signal, AbortSignal.timeout(5000)]);
    try {
      await audio.resume();
      for (const clip of clips) {
        const response = await fetch(`/dev/audio/${clip}.wav`, {cache: 'no-store', signal});
        if (!response.ok) throw new Error('Generate the test clips with scripts/recorded_audio.sh, then reconnect.');
        const data = await response.arrayBuffer();
        if (data.byteLength > 2 * 1024 * 1024) throw new Error('A test clip exceeds the 2 MB limit.');
        const buffer = await audio.decodeAudioData(data);
        if (current !== generation) throw new Error('Recorded connection canceled.');
        if (buffer.duration > 20) throw new Error('A test clip exceeds the 20-second limit.');
        buffers[clip] = buffer;
      }
      destination = audio.createMediaStreamDestination();
      destination.channelCount = 1;
      // Keep one outgoing track alive between clips. Never connect input to local speakers.
      silence = audio.createConstantSource(); silence.offset.value = 0;
      silence.connect(destination); silence.start();
      status('Clips loaded. Waiting for the voice service…');
      return destination.stream;
    } catch (error) {
      if (current === generation) { close(); status(error.message); }
      throw error;
    }
  };
  const play = async clip => {
    if (!ready || muted || source || !context) return;
    const current = generation;
    const audio = context;
    // Reserve the slot before awaiting, so rapid clicks cannot overlap clips.
    const node = audio.createBufferSource(); source = node; buttons();
    try {
      await audio.resume();
      if (current !== generation || source !== node) return;
      node.buffer = buffers[clip]; node.connect(destination);
      node.onended = () => {
        if (source !== node) return;
        source = null; node.disconnect(); buttons();
        status(`${clip} clip finished. Check the captions and backend result.`);
      };
      status(`Playing ${clip} clip into the call (${node.buffer.duration.toFixed(1)} seconds).`);
      node.start();
    } catch (error) {
      if (current === generation) { stop(); status(`Clip failed: ${error.message}`); }
    }
  };
  window.OrderDeskRecordedInput = {
    open, close,
    update(callConnected, callReady, isRecorded, isMuted) {
      if (!ready && callReady && isRecorded) status('Ready for a recorded clip.');
      connected = callConnected; ready = callReady && isRecorded; muted = isMuted;
      if (muted) stop();
      buttons();
    }
  };
  el('recorded-connect').onclick = () => document.dispatchEvent(new Event('recorded-input-connect'));
  for (const clip of clips) el(`recorded-${clip}`).onclick = () => play(clip);
  el('recorded-stop').onclick = () => { stop(); status('Clip stopped. Audio already sent may still be processed.'); };
})();
