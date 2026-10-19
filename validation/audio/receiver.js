/* Dedicated validation page: decoded receiver PCM, not physical speaker evidence. */
window.benchmark = {events: [], samples: [], trackSamples: [], done: false};
document.querySelector('#start').onclick = async () => {
  const result = window.benchmark;
  try {
    const ac = new AudioContext({sampleRate: 48000});
    result.sampleRate = ac.sampleRate;
    await ac.audioWorklet.addModule('/capture.js');
    await ac.resume();
    const pc = new RTCPeerConnection({iceServers: []});
    const ws = new WebSocket(`ws://${location.host}/socket${location.search}`);
    const pending = [];
    let capture, recorder, recorded, heartbeat, trackReader, processorTrack, statsTimer;
    const trackReady = new Promise(resolve => {
      pc.ontrack = e => {
        const stream = new MediaStream([e.track]);
        const element = document.createElement('audio'); element.autoplay=true; element.srcObject=stream; element.volume=0; document.body.append(element); element.play();
        processorTrack=e.track.clone();
        trackReader=new MediaStreamTrackProcessor({track:processorTrack}).readable.getReader();
        result.trackCaptureError=null;
        (async()=>{
          try {
            while(true){
              const {value:data,done}=await trackReader.read();if(done)break;
              const samples=new Float32Array(data.numberOfFrames);
              data.copyTo(samples,{planeIndex:0,format:'f32-planar'});
              result.trackSampleRate=data.sampleRate;
              if(samples.some(x=>Math.abs(x)>.01)) {
                result.trackFirstSignalAtMs ??= performance.now();
                result.trackLastSignalAtMs = performance.now();
              }
              result.trackSamples.push(samples);data.close();
            }
          } catch(error){result.trackCaptureError=String(error);}
        })();
        const recordedChunks=[];
        recorder = new MediaRecorder(stream, {mimeType:'audio/webm;codecs=opus',audioBitsPerSecond:128000});
        recorder.ondataavailable=e=>{if(e.data.size)recordedChunks.push(e.data);};
        recorded=new Promise(resolve=>recorder.onstop=async()=>{
          const bytes=new Uint8Array(await new Blob(recordedChunks).arrayBuffer());
          let binary='';for(let i=0;i<bytes.length;i+=8192)binary+=String.fromCharCode(...bytes.subarray(i,i+8192));
          result.webm=btoa(binary);resolve();
        });
        recorder.start(250);
        const source = ac.createMediaStreamSource(stream);
        capture = new AudioWorkletNode(ac, 'capture');
        capture.port.onmessage = e => { result.captureStartAudioTime ??= e.data.at;
          result.captureDiscontinuities ??= 0;
          if(result.captureNextFrame !== undefined && result.captureNextFrame !== e.data.frame) result.captureDiscontinuities++;
          result.captureNextFrame=e.data.frame+e.data.samples.length; result.samples.push(e.data.samples); };
        const mute = ac.createGain(); mute.gain.value = 0.000001;
        source.connect(capture).connect(mute).connect(ac.destination);
        resolve();
      };
    });
    const send = message => ws.send(JSON.stringify(message));
    pc.onicecandidate = e => {if(e.candidate) send({type:'candidate',candidate:e.candidate.toJSON()});};
    const silent = ac.createMediaStreamDestination();
    const oscillator = ac.createOscillator(); const zero = ac.createGain(); zero.gain.value=0;
    oscillator.connect(zero).connect(silent); oscillator.start();
    pc.addTrack(silent.stream.getAudioTracks()[0], silent.stream);
    ws.onmessage = async e => {
      const m = JSON.parse(e.data); result.events.push(m);
      if(m.type === 'answer') {
        await pc.setRemoteDescription(m);
        for(const c of pending.splice(0)) await pc.addIceCandidate(c);
      } else if(m.type === 'candidate') {
        if(pc.remoteDescription) await pc.addIceCandidate(m.candidate); else pending.push(m.candidate);
      } else if(m.type === 'ready') {
        await trackReady;
        await new Promise(r=>setTimeout(r,500));
        result.warmStats = Array.from((await pc.getStats()).values());
        result.runAtMs = performance.now();
        result.runAudioTime = ac.currentTime;
        send({type:'run'});
        if(new URLSearchParams(location.search).get('trace')==='1') {
          result.receiverTimeline=[];
          let sampling=false;
          statsTimer=setInterval(async()=>{
            if(sampling)return;
            sampling=true;
            try {
              const stats=Array.from((await pc.getStats()).values());
              const incoming=stats.find(s=>s.type==='inbound-rtp'&&s.kind==='audio');
              if(incoming && result.receiverTimeline.length<4096) {
                result.receiverTimeline.push({at_ms:performance.now()-result.runAtMs,
                  packetsReceived:incoming.packetsReceived,packetsLost:incoming.packetsLost,packetsDiscarded:incoming.packetsDiscarded,
                  concealedSamples:incoming.concealedSamples,concealmentEvents:incoming.concealmentEvents,
                  totalSamplesReceived:incoming.totalSamplesReceived,
                  insertedSamplesForDeceleration:incoming.insertedSamplesForDeceleration,
                  removedSamplesForAcceleration:incoming.removedSamplesForAcceleration,
                  jitter:incoming.jitter,jitterBufferDelay:incoming.jitterBufferDelay,
                  jitterBufferTargetDelay:incoming.jitterBufferTargetDelay,
                  jitterBufferEmittedCount:incoming.jitterBufferEmittedCount});
              }else if(incoming){result.receiverTimelineTruncated=true;}
            }catch(error){if(pc.connectionState!=='closed')result.receiverTimelineError=String(error);}
            finally{sampling=false;}
          },100);
        }
        const mode = new URLSearchParams(location.search).get('mode');
        result.mode = mode || 'normal';
        if(mode === 'interrupt') setTimeout(()=>send({type:'interrupt'}), 2000);
        if(mode === 'disconnect') setTimeout(async()=>{
          result.stats = Array.from((await pc.getStats()).values());
          result.intentionalDisconnect = true; send({type:'disconnect'});
        },2000);
      } else if(m.type === 'started') {
        result.serverStartReceivedAtMs=performance.now();
      } else if(m.type === 'finished') {
        await new Promise(r=>setTimeout(r,500));
        result.stats = Array.from((await pc.getStats()).values());
        result.finished = m.data;
        send({type:'disconnect'});
      }
    };
    ws.onclose = async () => {
      clearInterval(heartbeat);
      clearInterval(statsTimer);
      if(recorder && recorder.state!=='inactive'){recorder.stop();await recorded;}
      await trackReader?.cancel(); processorTrack?.stop();
      pc.close(); capture?.disconnect(); await ac.close();
      result.done = true; document.querySelector('#status').textContent = 'Capture complete';
    };
    await new Promise((resolve,reject)=>{ws.onopen=resolve;ws.onerror=reject;});
    heartbeat=setInterval(()=>send({type:'ping'}),5000);
    await pc.setLocalDescription(await pc.createOffer());
    send(pc.localDescription.toJSON());
    document.querySelector('#status').textContent = 'Capturing synthetic audio…';
  } catch(e) { result.error=String(e);result.done=true; }
};
