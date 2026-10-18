'use strict';
(() => {
  const el = id => document.getElementById(id);
  let attempt = 0;
  let pc, socket, microphone, timer, connecting = false, muted = false;
  let captions = [], events = [], pendingCandidates = [];
  let ready = false, recorded = false, captionEpoch = 0;
  const note = message => {
    events.push(`${new Date().toLocaleTimeString()} ${message}`);
    events = events.slice(-200);
    el('events').textContent = events.join('\n');
  };
  const status = message => { el('connection').textContent = message; note(message); };
  const send = message => {
    if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
  };
  const buttons = connected => {
    el('connect').disabled = connected;
    el('connect').textContent = connecting && !ready ? 'Connecting…' : 'Connect microphone';
    el('disconnect').disabled = !connected;
    for (const name of ['mute', 'stop', 'clear', 'resume', 'status']) el(name).disabled = !ready;
    window.OrderDeskRecordedInput?.update(connected, ready, recorded, muted);
  };
  const cleanup = message => {
    attempt++; connecting = false;
    clearInterval(timer);
    const oldSocket = socket; socket = null;
    if (oldSocket) { oldSocket.onclose = null; oldSocket.close(); }
    if (pc) {
      const peer = pc; pc = null; peer.onconnectionstatechange = null;
      if (window.OrderDeskAudioDiagnostics) window.OrderDeskAudioDiagnostics.finish(peer);
      else peer.close();
    }
    microphone?.getTracks().forEach(track => track.stop()); microphone = null;
    if (recorded) window.OrderDeskRecordedInput?.close();
    recorded = false;
    el('speaker').srcObject = null;
    muted = false; ready = false; el('mute').textContent = 'Mute microphone';
    el('mute').setAttribute('aria-pressed', 'false');
    el('microphone-state').textContent = 'Your microphone is off.';
    el('playback-feedback').textContent = '';
    el('media-path').textContent = 'Media path: disconnected';
    pendingCandidates = []; buttons(false); status(message);
  };
  const resetCaptions = () => {
    captions = []; captionEpoch = 0;
    const transcript = el('transcript');
    const empty = document.createElement('p');
    empty.className = 'empty';
    empty.textContent = 'Your new conversation will appear here.';
    transcript.replaceChildren(empty);
    transcript.scrollTop = 0;
  };
  const caption = payload => {
    const last = captions.at(-1);
    const segment = payload.segment_id ?? payload.item_id ?? null;
    const timed = Number.isFinite(payload.start_ms) && Number.isFinite(payload.end_ms)
      && payload.start_ms >= 0 && payload.end_ms >= payload.start_ms;
    // GPT Live has no reply IDs. A one-second session-timeline gap starts a
    // display row, not a conversational turn, playback boundary or tool action.
    // Search retained rows so overlapping speakers and late captions can update
    // their own group. Packet arrival delays never create a boundary.
    const entry = segment !== null
      ? captions.findLast(row => row.epoch === captionEpoch && row.speaker === payload.speaker && row.segment === segment)
      : timed
        ? captions.findLast(row => row.epoch === captionEpoch && row.speaker === payload.speaker && row.segment === null
          && row.start_ms !== null && payload.start_ms < row.end_ms + 1000
          && payload.end_ms > row.start_ms - 1000)
        : last?.epoch === captionEpoch && last.speaker === payload.speaker && last.segment === null && last.start_ms === null ? last : null;
    if (entry) {
      // Preserve fragments exactly, including split words and corrections.
      entry.text += payload.delta;
      if (timed) {
        entry.start_ms = Math.min(entry.start_ms ?? payload.start_ms, payload.start_ms);
        entry.end_ms = Math.max(entry.end_ms ?? payload.end_ms, payload.end_ms);
      }
    } else {
      const row = {epoch: captionEpoch, speaker: payload.speaker, segment, text: payload.delta,
        start_ms: timed ? payload.start_ms : null, end_ms: timed ? payload.end_ms : null};
      // Place a late first interval before later timed groups. Untimed captions
      // and native reply IDs keep their original display order.
      const later = timed && segment === null
        ? captions.findIndex(other => other.epoch === captionEpoch && other.segment === null && other.start_ms !== null && other.start_ms > row.start_ms)
        : -1;
      if (later < 0) captions.push(row);
      else captions.splice(later, 0, row);
    }
    captions = captions.slice(-100);
    // Captions are display groups, not conversation turn boundaries.
    for (const entry of captions) entry.text = entry.text.slice(-10000);
    // A pause cannot distinguish a trailing draft reminder from a save reply.
    // For unsegmented timed captions, render sentences independently even when
    // adjacent sentences arrive in one delta. Re-segment the retained text so
    // split words, decimal points and closing quotes keep their original text.
    const sentences = new Intl.Segmenter('en', {granularity: 'sentence'});
    const rows = captions.flatMap(entry => entry.segment === null && entry.start_ms !== null
      ? Array.from(sentences.segment(entry.text), part => ({speaker: entry.speaker, text: part.segment}))
      : [entry]).slice(-100);
    const transcript = el('transcript');
    const following = transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < 48;
    transcript.querySelector('.empty')?.remove();
    while (transcript.children.length > rows.length) transcript.firstElementChild.remove();
    // Keep existing caption nodes so each fragment doesn't re-announce the entire log.
    rows.forEach((entry, index) => {
      let p = transcript.children[index];
      if (!p || p.dataset.speaker !== entry.speaker) {
        p = document.createElement('p'); p.dataset.speaker = entry.speaker;
        const label = document.createElement('strong'); label.textContent = entry.speaker === 'user' ? 'You' : 'Assistant';
        p.append(label, document.createTextNode(''));
        if (transcript.children[index]) transcript.children[index].replaceWith(p);
        else transcript.append(p);
      }
      if (p.lastChild.textContent !== entry.text) p.lastChild.textContent = entry.text;
    });
    if (following) transcript.scrollTop = transcript.scrollHeight;
  };
  const receive = async message => {
    if (!pc) return;
    switch (message.type) {
      case 'attached': {
        window.OrderDeskAudioDiagnostics?.bind(message.session_id);
        const offer = await pc.createOffer();
        await pc.setLocalDescription(offer);
        send({type: 'offer', sdp: offer.sdp});
        for (const candidate of pendingCandidates) send({type: 'candidate', candidate});
        pendingCandidates = []; pc.offerSent = true;
        break;
      }
      case 'answer': await pc.setRemoteDescription(message); break;
      case 'candidate': await pc.addIceCandidate(message.candidate); break;
      case 'ready': ready = true; connecting = false; buttons(true); status(recorded ? 'Ready — wait for the greeting, then play a recorded clip.' : 'Ready — wait for the greeting, then speak.'); await showPath(); break;
      case 'transcript': caption(message.payload); break;
      case 'event':
        if (message.event === 'output_recovery_requested') {
          captionEpoch++;
          status('Recovering the assistant’s audio. Your call is still connected.');
        } else if (message.event === 'output_recovered') {
          status('Assistant audio restored. Please repeat your last request.');
        }
        if (message.event === 'response_status') {
          if (message.payload.status === 'delayed') {
            status('The assistant is taking longer to respond. The call is still connected.');
          } else {
            status('Connected');
          }
        }
        if (message.event === 'failed') {
          cleanup(['command_ack_timeout', 'progress_timeout'].includes(message.payload?.cause)
            ? 'The voice service stopped responding. Reconnect to try again; review any existing drafts before making changes.'
            : 'The voice connection failed. Reconnect to try again.');
        } else note(JSON.stringify(message));
        break;
      case 'closed': cleanup('Session closed'); break;
      case 'control':
        el('playback-feedback').textContent = message.accepted
          ? `${({stop: 'Output stopped.', clear: 'Parlora’s audio queue cleared.', resume: 'Output resumed.'})[message.action] || 'Audio control accepted.'} Audio already sent to the browser may still play.`
          : 'Audio control was not accepted. Try again.';
        note(JSON.stringify(message)); break;
      case 'pong': break;
      default: note(JSON.stringify(message));
    }
  };
  const selectedPath = async () => {
    const peer = pc;
    if (!peer) return null;
    const stats = await peer.getStats();
    const transport = [...stats.values()].find(row => row.type === 'transport' && row.selectedCandidatePairId);
    const pair = transport && stats.get(transport.selectedCandidatePairId);
    if (!pair || pc !== peer) return null;
    const local = stats.get(pair.localCandidateId), remote = stats.get(pair.remoteCandidateId);
    return {local: local?.candidateType, remote: remote?.candidateType,
      protocol: local?.protocol, relay_protocol: local?.relayProtocol || null,
      bytes_sent: pair.bytesSent, bytes_received: pair.bytesReceived};
  };
  const showPath = async () => {
    const route = await selectedPath();
    if (!route) return;
    const relayed = route.local === 'relay' || route.remote === 'relay';
    el('media-path').textContent = `Media path: ${relayed ? 'TURN relay' : 'direct'} (browser: ${route.local}, server: ${route.remote}${route.relay_protocol ? `; TURN ${route.relay_protocol}` : ''})`;
  };
  window.parloraConnectionPath = selectedPath;
  const connect = async (useRecording = false) => {
    if (connecting || pc) return;
    const current = ++attempt;
    resetCaptions();
    recorded = useRecording;
    connecting = true; buttons(true); status(recorded ? 'Preparing recorded input…' : 'Requesting microphone permission…');
    try {
      if (!window.isSecureContext) throw new Error('Open this page over HTTPS or localhost.');
      const recording = recorded ? await window.OrderDeskRecordedInput.open() : null;
      if (current !== attempt) return;
      const response = await fetch('/ice-config', {method: 'POST', cache: 'no-store', signal: AbortSignal.timeout(5000)});
      if (!response.ok) throw new Error('Cannot obtain ICE configuration. Check the application server.');
      const iceConfig = await response.json();
      if (current !== attempt) return;
      const stream = recording || await navigator.mediaDevices.getUserMedia({audio: {echoCancellation: true, noiseSuppression: true, autoGainControl: true}, video: false});
      if (current !== attempt) { stream.getTracks().forEach(track => track.stop()); return; }
      microphone = stream;
      el('mute').textContent = recorded ? 'Mute recorded input' : 'Mute microphone';
      el('microphone-state').textContent = recorded ? 'Recorded input connected. Your microphone is off.' : 'Microphone on.';
      pc = new RTCPeerConnection(iceConfig);
      window.OrderDeskAudioDiagnostics?.start(pc);
      microphone.getTracks().forEach(track => pc.addTrack(track, microphone));
      pc.ontrack = async event => {
        el('speaker').srcObject = new MediaStream([event.track]);
        try { await el('speaker').play(); } catch (_) { el('playback-controls').open = true; status('Press Play in the audio player to enable sound.'); }
      };
      pc.onicecandidate = event => {
        if (!event.candidate) return;
        const candidate = event.candidate.toJSON();
        if (pc.offerSent) send({type: 'candidate', candidate});
        else pendingCandidates.push(candidate);
      };
      pc.onicecandidateerror = event => note(`ICE server error ${event.errorCode}; check server reachability and TURN credentials.`);
      pc.onconnectionstatechange = () => {
        note(`Media connection: ${pc.connectionState}`);
        if (['failed', 'disconnected'].includes(pc.connectionState)) cleanup('Media disconnected — reconnect to start a new session.');
      };
      socket = new WebSocket(`${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/voice`);
      socket.onopen = () => { status('Connecting media and voice service…'); timer = setInterval(() => { send({type: 'ping'}); showPath().catch(() => {}); }, 5000); };
      let messages = Promise.resolve();
      socket.onmessage = event => { messages = messages.then(() => current === attempt && receive(JSON.parse(event.data))).catch(() => { if (current === attempt) cleanup('Connection failed. Try connecting again.'); }); };
      socket.onclose = () => cleanup(ready ? 'Session closed — reconnect to start a new session.' : 'Connection closed before readiness — check the server log and ICE configuration.');
      socket.onerror = () => cleanup('Signaling connection failed.');
      // Numeric WebRTC statistics are available to the validation harness, without recording audio.
      window.parloraBrowserStats = () => pc?.getStats().then(stats => [...stats.values()].filter(row => ['inbound-rtp', 'outbound-rtp', 'candidate-pair', 'media-playout', 'media-source'].includes(row.type)));
    } catch (error) { if (current === attempt) cleanup(error.name === 'NotAllowedError' ? 'Microphone permission denied. Allow access and reconnect.' : error.message); }
  };
  el('connect').onclick = () => connect();
  document.addEventListener('recorded-input-connect', () => { if (window.OrderDeskRecordedInput) connect(true); });
  el('disconnect').onclick = () => { send({type: 'disconnect'}); cleanup('Disconnected'); };
  el('mute').onclick = () => {
    muted = !muted; microphone?.getAudioTracks().forEach(track => { track.enabled = !muted; });
    el('mute').textContent = recorded ? (muted ? 'Unmute recorded input' : 'Mute recorded input') : (muted ? 'Unmute microphone' : 'Mute microphone');
    el('mute').setAttribute('aria-pressed', String(muted));
    el('microphone-state').textContent = recorded
      ? (muted ? 'Recorded input muted. Your microphone is off.' : 'Recorded input connected. Your microphone is off.')
      : (muted ? 'Microphone muted. You can still hear the assistant.' : 'Microphone on.');
    window.OrderDeskRecordedInput?.update(true, ready, recorded, muted);
    note(`${recorded ? 'Recorded input' : 'Microphone'} ${muted ? 'muted' : 'unmuted'}; conversation output and backend work continue.`);
  };
  for (const action of ['stop', 'clear', 'resume']) el(action).onclick = () => send({type: 'control', action});
  el('status').onclick = () => { send({type: 'status'}); showPath().catch(() => {}); };
  window.addEventListener('pagehide', () => cleanup('Page closed'));
})();
