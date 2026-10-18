'use strict';
(() => {
  // Numeric observations only. Server and browser clocks are kept separate.
  const fields = ['timestamp', 'packetsReceived', 'packetsLost', 'packetsSent', 'bytesReceived',
    'bytesSent', 'jitter', 'jitterBufferDelay', 'jitterBufferEmittedCount', 'jitterBufferTargetDelay',
    'jitterBufferMinimumDelay', 'concealedSamples', 'silentConcealedSamples', 'concealmentEvents',
    'totalSamplesReceived', 'insertedSamplesForDeceleration', 'removedSamplesForAcceleration',
    'totalPlayoutDelay', 'totalSamplesCount', 'synthesizedSamplesDuration', 'synthesizedSamplesEvents',
    'totalRoundTripTime', 'currentRoundTripTime', 'responsesReceived', 'availableIncomingBitrate',
    'availableOutgoingBitrate'];
  const types = ['inbound-rtp', 'outbound-rtp', 'candidate-pair', 'media-playout'];
  let current, history = [];
  const summary = document.createElement('pre');
  summary.id = 'audio-diagnostics-summary'; summary.setAttribute('aria-label', 'Audio trace summary');
  summary.textContent = 'Numeric audio tracing enabled. Connect to start a new report.';
  const download = document.createElement('button'); download.textContent = 'Download numeric audio report';
  download.disabled = true;
  document.getElementById('diagnostics').append(summary, download);
  const render = report => {
    const source = report.server;
    summary.textContent = JSON.stringify({session_id: report.session_id, state: report.state,
      receiver_samples: report.receiver.length, receiver_truncated: report.receiver_truncated,
      stats_failures: report.stats_failures, final_stats: report.final_stats,
      server_events: source?.events_seen ?? null, server_truncated: source?.truncated ?? null,
      server_closed: source?.closed ?? null, server_error: report.server_error ?? null}, null, 2);
    download.disabled = report.state !== 'finished';
  };
  const sample = async (peer, report) => {
    try {
      const stats = await Promise.race([peer.getStats(), new Promise((_, reject) =>
        setTimeout(() => reject(new Error('stats timeout')), 250))]);
      const values = [...stats.values()].filter(row => types.includes(row.type)
        && (row.kind === undefined || row.kind === 'audio')
        && (row.type !== 'candidate-pair' || row.nominated === true))
        .slice(0, 16).map(row => ({type: row.type, ...Object.fromEntries(fields.filter(key =>
          Number.isFinite(row[key])).map(key => [key, row[key]]))}));
      if (report.receiver.length < 240) report.receiver.push({at_ms: performance.now() - report.origin_ms, stats: values});
      else report.receiver_truncated = true;
      return true;
    } catch (_) { report.stats_failures++; return false; }
  };
  const loadServer = async report => {
    if (!report.session_id) { report.server_error = 'session_not_attached'; return; }
    const url = `/api/audio-diagnostics?session_id=${encodeURIComponent(report.session_id)}`;
    try {
      for (let i = 0; i < 10; i++) {
        const response = await fetch(`${url}&summary=1`, {cache: 'no-store', signal: AbortSignal.timeout(2000)});
        if (!response.ok) throw new Error('trace unavailable');
        const call = (await response.json()).calls.find(call => call.session_id === report.session_id);
        if (call?.closed || i === 9) break;
        await new Promise(resolve => setTimeout(resolve, 500));
      }
      const response = await fetch(url, {cache: 'no-store', signal: AbortSignal.timeout(5000)});
      if (!response.ok) throw new Error('trace unavailable');
      report.server = (await response.json()).calls.find(call => call.session_id === report.session_id) ?? null;
      if (!report.server) report.server_error = 'session_trace_missing';
    } catch (_) { report.server_error = 'trace_unavailable'; }
  };
  window.OrderDeskAudioDiagnostics = {
    start(peer) {
      const report = {schema_version: 1, session_id: null, state: 'recording', clock: 'browser_performance',
        origin_ms: performance.now(), started_at: new Date().toISOString(), receiver: [],
        receiver_truncated: false, stats_failures: 0, final_stats: null, server: null};
      current = report; history = [...history.slice(-3), report];
      let busy = false;
      report.timer = setInterval(async () => {
        if (busy) return;
        busy = true; await sample(peer, report); busy = false;
        if (current === report) render(report);
      }, 1000);
      render(report);
    },
    bind(id) { if (current && typeof id === 'string') {
      current.session_id = id; current.attached_at_ms = performance.now() - current.origin_ms;
    } },
    async finish(peer) {
      const report = current;
      if (!report || report.state !== 'recording') { peer.close(); return; }
      clearInterval(report.timer); delete report.timer; report.state = 'finishing';
      report.final_stats = await sample(peer, report);
      peer.close();
      await loadServer(report); report.state = 'finished';
      if (current === report) render(report);
    }
  };
  window.parloraAudioDiagnostics = () => JSON.parse(JSON.stringify(history.map(({timer, ...report}) => report)));
  download.onclick = () => {
    const blob = new Blob([JSON.stringify(window.parloraAudioDiagnostics(), null, 2)], {type: 'application/json'});
    const url = URL.createObjectURL(blob), link = document.createElement('a');
    link.href = url; link.download = 'parlora-audio-diagnostics.json'; link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  };
})();
