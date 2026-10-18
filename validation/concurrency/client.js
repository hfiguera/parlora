/* Synthetic input and decoded remote capture. No microphone or physical speakers. */
window.probe={events:[],chunks:[],ready:false,closed:false,captured:0};
document.querySelector('#start').onclick=async()=>{
 const r=window.probe;
 try {
  const params=new URLSearchParams(location.search),slot=Number(params.get('slot')||1);
  const ac=new AudioContext({sampleRate:48000});await ac.resume();
  const pc=new RTCPeerConnection({iceServers:[]});
  const ws=new WebSocket(`ws://${location.host}${params.get('socket')}`);
  let pending=[],reader,track,ping,poll,closing=false;
  const send=m=>{if(ws.readyState===WebSocket.OPEN)ws.send(JSON.stringify(m));};
  const oscillator=ac.createOscillator(),gain=ac.createGain(),input=ac.createMediaStreamDestination();
  oscillator.frequency.value=300+slot*400;gain.gain.value=.18;
  oscillator.connect(gain).connect(input);oscillator.start();
  pc.addTrack(input.stream.getAudioTracks()[0],input.stream);
  pc.ontrack=e=>{
   const audio=document.createElement('audio');audio.autoplay=true;audio.volume=0;
   audio.srcObject=new MediaStream([e.track]);document.body.append(audio);audio.play().catch(()=>{});
   track=e.track.clone();reader=new MediaStreamTrackProcessor({track}).readable.getReader();
   (async()=>{try{while(true){const {value:data,done}=await reader.read();if(done)break;
    const samples=new Float32Array(data.numberOfFrames);data.copyTo(samples,{planeIndex:0,format:'f32-planar'});
    r.rate=data.sampleRate;r.channels=data.numberOfChannels;
    if(r.firstSignalMs===undefined&&samples.some(x=>Math.abs(x)>.01))r.firstSignalMs=performance.now();
    if(r.captured+samples.length<=r.rate*30){r.chunks.push(samples);r.captured+=samples.length;}else r.truncated=true;
    data.close();
   }}catch(e){if(!closing)r.captureError=String(e);}})();
  };
  pc.onicecandidate=e=>{if(e.candidate)send({type:'candidate',candidate:e.candidate.toJSON()});};
  ws.onmessage=async e=>{try{
   const m=JSON.parse(e.data);
   if(!['candidate','answer','pong'].includes(m.type))r.events.push({at_ms:performance.now(),...m});
   if(m.type==='attached'){await pc.setLocalDescription(await pc.createOffer());send(pc.localDescription.toJSON());}
   if(m.type==='answer'){await pc.setRemoteDescription(m);for(const c of pending.splice(0))await pc.addIceCandidate(c);}
   if(m.type==='candidate'){if(pc.remoteDescription)await pc.addIceCandidate(m.candidate);else pending.push(m.candidate);}
   if(m.type==='ready'){r.ready=true;r.readyAtMs=performance.now();poll=setInterval(()=>send({type:'status'}),500);}
  }catch(e){r.error=String(e);}};
  ws.onopen=()=>{ping=setInterval(()=>send({type:'ping'}),5000);};
  ws.onerror=()=>{r.socketError=true;};
  async function stats(){return [...(await pc.getStats()).values()].filter(s=>['inbound-rtp','outbound-rtp'].includes(s.type)).map(s=>Object.fromEntries(Object.entries(s).filter(([k,v])=>['type','kind'].includes(k)||typeof v==='number')));}
  window.sampleProbe=async()=>({ready:r.ready,closed:r.closed,stats:await stats(),captured:r.captured});
  window.disconnectProbe=()=>send({type:'disconnect'});
  ws.onclose=async e=>{closing=true;clearInterval(ping);clearInterval(poll);r.closeCode=e.code;r.closeAtMs=performance.now();
   try{r.stats=await stats();await reader?.cancel();track?.stop();pc.close();oscillator.stop();await ac.close();}catch(e){r.closeError=String(e);}
   r.closed=true;
  };
 }catch(e){r.error=String(e);r.closed=true;}
};
window.exportProbe=()=>{
 const r=window.probe,bytes=new Uint8Array(r.captured*2),view=new DataView(bytes.buffer);let n=0;
 for(const chunk of r.chunks)for(const x of chunk)view.setInt16(2*n++,Math.round(Math.max(-1,Math.min(1,x))*32767),true);
 let text='';for(let i=0;i<bytes.length;i+=8192)text+=String.fromCharCode(...bytes.subarray(i,i+8192));
 return {...r,chunks:undefined,pcm:btoa(text)};
};
