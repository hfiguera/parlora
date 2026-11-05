(() => {
  'use strict';
  const roots = [...document.querySelectorAll('[data-booking-replay]')];
  function initPlayer(root) {
    const audio = root.querySelector('audio');
    const select = root.querySelector('select');
    const status = root.querySelector('[data-replay-status]');
    const plot = root.querySelector('[data-replay-plot]');
    const transcript = root.querySelector('[data-replay-transcript]');
    const moments = root.querySelector('[data-replay-moments]');
    const caption = root.querySelector('[data-replay-caption]');
    const summary = root.querySelector('[data-replay-summary]');
    const activity = root.querySelector('[data-replay-activity]');
    const activityList = root.querySelector('[data-replay-activity-list]');
    const activityTime = root.querySelector('[data-replay-activity-time]');
    const waveNote = root.querySelector('[data-replay-wave-note]');
    const base = root.dataset.bookingReplay;
    let recording, request = 0, captions = [], frame = 0, activityKey = '', momentButtons = [], waveRows = [];
    const time = ms => `${Math.floor(ms / 60000)}:${String(Math.floor(ms / 1000) % 60).padStart(2, '0')}`;
    const elapsed = ms => `${Math.max(0, ms / 1000).toFixed(ms < 1000 ? 2 : 1)} s`;
    const lanes = [['jev', 'JEV judgment'], ['policy', 'App policy'], ['backend', 'Jido work'], ['delivery', 'Result delivery']];
    const node = (tag, className, text) => {
      const element = document.createElement(tag);
      if (className) element.className = className;
      if (text !== undefined) element.textContent = text;
      return element;
    };
    const jump = (at, text) => {
      const button = node('button', 'replay-jump', text);
      button.type = 'button';
      button.addEventListener('click', () => { audio.currentTime = (Math.floor(at) + 1) / 1000; update(); });
      return button;
    };
    const speakerName = (speaker, data) => data.caption_labels?.[speaker] || (speaker === 'user' ? 'Caller' : 'Assistant');
    const dateLabel = iso => /^\d{4}-\d{2}-\d{2}$/.test(iso || '') ? new Intl.DateTimeFormat('en-US', {weekday:'short', month:'short', day:'numeric', timeZone:'UTC'}).format(new Date(iso + 'T12:00:00Z')) : '';
    function jobTitle(job) {
      const titles = {lookup:'Find patient record', insurance:'Review insurance on file', availability:'Check availability', propose:'Prepare appointment for approval', confirm:'Book the appointment', reminder_opt_in:'Record text reminder preference', reminder_confirm:'Schedule text reminder', reminder_number:'Check new cell number', reminder_change:'Update reminder destination', reminder_decline:'Save reminder preference'};
      const date = dateLabel(job.input?.date);
      return (titles[job.operation] || 'Run backend action') + (job.operation === 'availability' && date ? ` · ${date}` : '');
    }
    function waveform(values, speaker, title) {
      const row = node('div', `replay-row replay-speaker replay-speaker-${speaker}`);
      row.dataset.speaker = speaker;
      row.append(node('span', 'replay-label', title));
      const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
      svg.setAttribute('viewBox', '0 0 1000 64'); svg.setAttribute('preserveAspectRatio', 'none');
      svg.setAttribute('role', 'img'); svg.setAttribute('aria-label', `${title}: recorded audio level over time`);
      svg.classList.add('replay-wave'); svg.dataset.waveform = speaker;
      const baseline = document.createElementNS(svg.namespaceURI, 'line');
      for (const [key, value] of Object.entries({x1:0, x2:1000, y1:32, y2:32})) baseline.setAttribute(key, value);
      baseline.setAttribute('class', 'replay-wave-baseline'); svg.append(baseline);
      const upper = values.map((value, i) => `${(i / Math.max(1, values.length - 1) * 1000).toFixed(2)},${(32 - value * 30).toFixed(2)}`);
      const lower = values.map((value, i) => `${(i / Math.max(1, values.length - 1) * 1000).toFixed(2)},${(32 + value * 30).toFixed(2)}`).reverse();
      for (const className of ['replay-wave-future', 'replay-wave-played']) {
        const path = document.createElementNS(svg.namespaceURI, 'path');
        path.setAttribute('d', `M${upper.join(' L')} L${lower.join(' L')} Z`); path.setAttribute('class', className); svg.append(path);
      }
      row.append(svg); plot.append(row); waveRows.push(row);
    }
    function eventsFor(data) {
      const names = {'caller:correction':'Caller changes the date', 'caller:confirm':'Caller approves the appointment', 'caller:progress':'Caller asks about booking progress', stale_result:'Earlier result filtered'};
      const jobs = data.backend_activity || [];
      const result = [];
      for (const marker of data.markers) {
        let label = names[marker.name];
        if (marker.name === 'caller:preparation') label = jobs.some(j => j.operation === 'availability' && j.start <= marker.at && (j.end == null || marker.at < j.end)) ? 'Conversation continues during lookup' : 'Caller asks what to bring';
        if (label) result.push({at:marker.at, label, name:marker.name});
      }
      for (const job of jobs) {
        if (job.result?.status !== 'completed') continue;
        const facts = job.result.facts || {};
        if (facts.confirmation) result.push({at:job.result.at, label:'Backend confirms the booking', name:'booking_confirmed'});
        if (facts.reminder?.status === 'scheduled') result.push({at:job.result.at, label:'Simulated text reminder saved', name:'reminder_saved'});
      }
      return result.sort((a,b) => a.at - b.at);
    }
    function render(data, audioBase) {
      plot.replaceChildren(); transcript.replaceChildren(); moments.replaceChildren();
      momentButtons = []; waveRows = []; activityKey = '';
      const duration = data.duration_ms;
      const scale = node('div', 'replay-scale');
      for (const fraction of [0, .25, .5, .75, 1]) scale.append(node('span', '', time(duration * fraction)));
      plot.append(scale);
      if (data.waveforms?.caller && data.waveforms?.assistant) {
        waveform(data.waveforms.caller, 'user', data.ambience ? 'Caller + café' : 'Caller');
        waveform(data.waveforms.assistant, 'assistant', 'Assistant');
        waveNote.textContent = data.ambience ? 'Caller input includes the continuous café background. Both tracks use the same amplitude scale.' : 'Separate recorded tracks, shown on the same time and amplitude scale.';
      } else {
        waveform(data.waveform, 'mixed', 'Conversation');
        waveNote.textContent = 'This earlier recording has a combined waveform.';
      }
      const jobs = new Map(data.markers.filter(m => m.name === 'task_submitted').map(m => [m.data.id, m.data.input]));
      for (const [key, title] of lanes) {
        const row = node('div', 'replay-row'); row.append(node('span', 'replay-label', title));
        const track = node('div', `replay-track replay-track-${key}`);
        for (const span of data.spans.filter(s => s.lane === key)) {
          const mark = node('span', `replay-span ${span.outcome === 'stale' ? 'replay-stale' : ''}`);
          mark.style.left = `${Math.max(0, span.start / duration * 100)}%`;
          mark.style.width = `${Math.max(0, (span.end - span.start) / duration * 100)}%`;
          const job = jobs.get(span.request);
          const description = job ? jobTitle({operation:job.operation,input:job}) : span.outcome;
          mark.title = `${title}: ${description}, ${time(span.start)}–${time(span.end)}, ${Math.round(span.end - span.start)} ms, ${span.outcome}`;
          mark.setAttribute('aria-label', mark.title);
          if ((span.end - span.start) / duration > .12) mark.textContent = description;
          track.append(mark);
        }
        row.append(track); plot.append(row);
      }
      const head = node('div', 'replay-playhead'); head.setAttribute('aria-hidden', 'true'); plot.append(head);
      for (const event of eventsFor(data)) {
        const button = jump(event.at, ''); button.classList.add('replay-moment'); button.dataset.event = event.name;
        button.append(node('span', 'replay-moment-time', time(event.at)), node('span', '', event.label));
        moments.append(button); momentButtons.push({...event, button});
      }
      captions = data.captions.map(part => {
        const item = node('li', 'replay-caption-row');
        item.append(jump(part.start, time(part.start)), node('strong', '', speakerName(part.speaker, data)), node('span', '', part.text.trim()));
        transcript.append(item); return {...part, element:item};
      });
      const passed = Object.values(data.checks).filter(Boolean).length;
      summary.textContent = `${data.model}${data.ambience ? ' · café background' : ''} · ${passed}/${Object.keys(data.checks).length} workflow checks passed · ${time(duration)} recorded`;
      const audioUrl = new URL(data.audio, audioBase); audioUrl.searchParams.set('v', data.audio_sha256.slice(0, 12)); audio.src = audioUrl.href;
      status.textContent = data.passed ? `Recorded call · fixed caller script · model-generated replies${data.ambience ? ' · café background' : ' · clean input'}` : `Recorded attempt · ${data.ambience ? 'café background · ' : ''}workflow did not complete`;
      activity.hidden = false; root.dataset.ready = 'true'; update();
    }
    async function load(name) {
      audio.pause(); cancelAnimationFrame(frame); audio.removeAttribute('src'); audio.replaceChildren(); audio.load();
      recording = undefined; activity.hidden = true; root.dataset.ready = 'false'; status.textContent = 'Loading recording…';
      const current = ++request;
      try {
        const response = await fetch(`${base}${name}.json`, {cache:'no-cache'});
        if (!response.ok) throw new Error('Recording unavailable');
        const data = await response.json();
        if (current !== request) return;
        recording = data; render(data, new URL('.', response.url));
      } catch (_) {
        if (current !== request) return;
        status.textContent = 'This recording could not load. Choose another recording or reload this page.';
        plot.replaceChildren(); transcript.replaceChildren(); moments.replaceChildren();
      }
    }
    function jobState(job, ms) {
      const result = job.result && job.result.at <= ms ? job.result : null;
      const delivered = job.delivery.filter(d => d.at <= ms).at(-1)?.stage;
      if (job.filtered_at != null && job.filtered_at <= ms || delivered === 'stale') return {state:'filtered', label:'Earlier result filtered', detail:'This result was no longer current and was not passed into the conversation.'};
      if (result?.status === 'failed' || job.end != null && job.end <= ms && ['failed','cancelled'].includes(job.outcome)) return {state:'failed', label:'Action failed', detail:'No successful result was confirmed for this action.'};
      if (!result && (job.end == null || ms < job.end)) {
        if (ms >= recording.duration_ms - 100) return {state:'unfinished', label:'No finish recorded', detail:'The recording ended before a completion was captured.'};
        return {state:'running', label:'Running', detail:job.replaced_at != null && job.replaced_at <= ms ? 'A newer request has replaced this lookup. This earlier action is still finishing.' : 'Backend work is in progress while the voice session remains open.'};
      }
      if (!result) return {state:'finished', label:'Work finished', detail:'Waiting for a captured result.'};
      const facts = result.facts || {};
      let detail = 'Backend action completed.';
      if (job.operation === 'lookup' && facts.patient_matched) detail = 'Patient record matched.';
      if (job.operation === 'insurance' && facts.insurance_confirmed) detail = 'Insurance details confirmed. Eligibility was not checked.';
      if (job.operation === 'availability' && facts.slots) detail = `${facts.slots.length} appointment ${facts.slots.length === 1 ? 'option' : 'options'} returned.`;
      if (job.operation === 'propose') detail = 'Appointment proposal prepared; booking still requires approval.';
      if (facts.confirmation) detail = `Appointment booked${facts.clinician_name ? ' with ' + facts.clinician_name : ''}.`;
      if (facts.reminder?.status === 'scheduled') detail = facts.reminder.simulated ? 'A simulated reminder was saved. No real text will be sent.' : 'Reminder setup confirmed by the backend.';
      if (facts.reminder?.status === 'verify_existing') detail = 'Reminder accepted; the cell number still needs confirmation.';
      if (facts.reminder?.status === 'declined') detail = 'Reminder preference saved; no text reminder requested.';
      const handoff = ['accepted','unconfirmed'].includes(delivered) ? 'Result submitted to the speech provider.' : delivered === 'awaiting_provider' ? 'Waiting to submit the result to the speech provider.' : delivered === 'awaiting_interpretation' ? 'Checking whether the result still applies.' : '';
      return {state:'completed', label:'Completed', detail:detail + (handoff ? ' ' + handoff : '')};
    }
    function updateActivity(ms) {
      const jobs = (recording.backend_activity || []).filter(job => job.start <= ms);
      const running = jobs.filter(job => (!job.result || job.result.at > ms) && (job.end == null || job.end > ms));
      const latest = jobs.filter(job => !running.includes(job)).sort((a,b) => Math.max(b.result?.at <= ms ? b.result.at : b.end || b.start, b.filtered_at <= ms ? b.filtered_at : 0) - Math.max(a.result?.at <= ms ? a.result.at : a.end || a.start, a.filtered_at <= ms ? a.filtered_at : 0))[0];
      const visible = [...running, ...(latest && running.length < 2 ? [latest] : [])];
      const rows = visible.map(job => ({job, ...jobState(job, ms)}));
      const key = rows.map(row => `${row.job.id}:${row.state}:${row.detail}`).join('|') + ':' + Math.floor(ms/1000);
      activityTime.textContent = `${time(ms)} into the call`;
      if (key === activityKey) return;
      activityKey = key; activityList.replaceChildren();
      if (!rows.length) {
        activityList.append(node('li', 'replay-activity-empty', recording.backend_activity ? 'No backend work has started at this point. Play the call or jump to a moment below.' : 'Backend activity details are unavailable for this earlier recording.'));
        return;
      }
      for (const row of rows) {
        const item = node('li', `replay-activity-item replay-activity-${row.state}`); item.dataset.state = row.state; item.dataset.operation = row.job.operation; item.dataset.request = row.job.id;
        const heading = node('div', 'replay-activity-title'); heading.append(node('strong', '', jobTitle(row.job)), node('span', 'replay-activity-state', row.label));
        const duration = row.job.end != null && row.job.end <= ms ? row.job.end-row.job.start : Math.max(0, ms-row.job.start);
        item.append(heading, node('p', 'replay-activity-detail', row.detail), node('span', 'replay-activity-timing', row.state === 'unfinished' ? `${time(row.job.start)} started · completion not captured` : `${time(row.job.start)} started · ${elapsed(duration)} ${row.state === 'running' ? 'elapsed' : 'execution'}`));
        activityList.append(item);
      }
    }
    function update() {
      if (!recording) return;
      const ms = audio.currentTime * 1000;
      plot.style.setProperty('--replay-progress', String(Math.max(0, Math.min(1, ms / recording.duration_ms))));
      let latest;
      const speaking = new Map();
      for (const part of captions) {
        const current = part.start <= ms && part.end + 1800 >= ms;
        part.element.classList.toggle('is-current', current);
        if (current) { part.element.setAttribute('aria-current', 'true'); latest = part; } else part.element.removeAttribute('aria-current');
        if (part.start <= ms && part.end >= ms) speaking.set(part.speaker, part);
      }
      for (const row of waveRows) row.classList.toggle('is-speaking', speaking.has(row.dataset.speaker));
      caption.textContent = speaking.size ? [...speaking.values()].map(part=>`${speakerName(part.speaker, recording)}: ${part.text.trim()}`).join('\n') : latest ? `${speakerName(latest.speaker, recording)}: ${latest.text.trim()}` : audio.paused && ms === 0 ? 'Press Play to hear the session and follow the work.' : 'Conversation continues; the timeline shows the work in progress.';
      const currentMoment = momentButtons.filter(event => event.at <= ms + 1).at(-1);
      for (const event of momentButtons) event.button.classList.toggle('is-current', event === currentMoment);
      updateActivity(ms);
    }
    function animate() { update(); if (!audio.paused) frame = requestAnimationFrame(animate); }
    select.addEventListener('change', () => load(select.value));
    audio.addEventListener('play', () => {
      for (const other of roots) if (other !== root) other.querySelector('audio').pause();
      cancelAnimationFrame(frame); animate();
    });
    for (const event of ['pause', 'ended', 'seeked', 'timeupdate']) audio.addEventListener(event, update);
    audio.addEventListener('error', () => { if (root.dataset.ready === 'true') status.textContent = 'Audio could not load. Try another recording or reload this page.'; });
    document.addEventListener('visibilitychange', () => { if (document.hidden) audio.pause(); });
    if ('IntersectionObserver' in window) new IntersectionObserver(entries => { if (!entries[0].isIntersecting) audio.pause(); }).observe(root);
    const requestedRecording = new URLSearchParams(location.search).get('recording');
    if ([...select.options].some(option => option.value === requestedRecording)) select.value = requestedRecording;
    load(select.value);
  }
  roots.forEach(initPlayer);
})();
