const {chromium} = require('../browser/node_modules/playwright');
const fs = require('node:fs/promises');
const path = require('node:path');
const {Worker} = require('node:worker_threads');
async function run() {
  const output = process.argv[2] || '/tmp/parlora-audio-receiver';
  await fs.mkdir(output,{recursive:true});
  const workerCount = Number(process.env.AUDIO_CPU_WORKERS || 0);
  if(!Number.isInteger(workerCount) || workerCount<0 || workerCount>8) throw Error('AUDIO_CPU_WORKERS must be 0..8');
  const seconds = Number(process.env.AUDIO_SECONDS || 10);
  if(!Number.isInteger(seconds) || seconds<3 || seconds>300) throw Error('AUDIO_SECONDS must be 3..300');
  const workers = Array.from({length:workerCount},()=>new Worker(`const end=Date.now()+${(seconds+5)*1000};let n=0;while(Date.now()<end){n+=Math.sqrt(Math.random());}`,{eval:true}));
  const browser = await chromium.launch({channel:process.env.BROWSER_CHANNEL || undefined,headless:true,args:['--autoplay-policy=no-user-gesture-required','--use-fake-device-for-media-stream']});
  try {
    const page=await browser.newPage();
    const trace = process.env.AUDIO_TIMELINE==='1' ? '&trace=1' : '';
    await page.goto(`http://127.0.0.1:4002/?scenario=${process.argv[3] || 'steady'}&mode=${process.argv[4] || 'normal'}${trace}`);
    await page.click('#start');
    await page.waitForFunction(()=>window.benchmark.done,null,{timeout:(seconds+35)*1000});
    const report=await page.evaluate(()=>{
      const r=window.benchmark;
      function encode(chunks) {
        const count=chunks.reduce((n,a)=>n+a.length,0);
        const pcm=new Uint8Array(count*2);const view=new DataView(pcm.buffer);
        let i=0;
        for(const chunk of chunks) for(const sample of chunk) view.setInt16(2*i++,Math.round(Math.max(-1,Math.min(1,sample))*32767),true);
        let binary='';for(let offset=0;offset<pcm.length;offset+=8192) binary+=String.fromCharCode(...pcm.subarray(offset,offset+8192));
        return btoa(binary);
      }
      return {...r,samples:undefined,trackSamples:undefined,pcm:encode(r.trackSamples),worklet:encode(r.samples)};
    });
    report.cpuWorkers = workerCount;
    if(report.webm){await fs.writeFile(path.join(output,'received.webm'),Buffer.from(report.webm,'base64'));delete report.webm;}
    const pcm=Buffer.from(report.pcm,'base64');delete report.pcm;
    report.events = report.events.map(e => ['answer','candidate'].includes(e.type) ? {type:e.type} : e);
    for(const key of ['stats','warmStats']) if(report[key]) report[key] = report[key].filter(s=>['inbound-rtp','outbound-rtp','media-playout'].includes(s.type));
    function wavHeader(bytes,rate){
      const wav=Buffer.alloc(44);wav.write('RIFF');wav.writeUInt32LE(36+bytes.length,4);wav.write('WAVEfmt ',8);
      wav.writeUInt32LE(16,16);wav.writeUInt16LE(1,20);wav.writeUInt16LE(1,22);wav.writeUInt32LE(rate,24);
      wav.writeUInt32LE(rate*2,28);wav.writeUInt16LE(2,32);wav.writeUInt16LE(16,34);wav.write('data',36);wav.writeUInt32LE(bytes.length,40);
      return Buffer.concat([wav,bytes]);
    }
    await fs.writeFile(path.join(output,'received.wav'),wavHeader(pcm,report.trackSampleRate || report.sampleRate));
    const worklet=Buffer.from(report.worklet,'base64');delete report.worklet;
    await fs.writeFile(path.join(output,'worklet.wav'),wavHeader(worklet,report.sampleRate));
    const reference=await fetch('http://127.0.0.1:4002/reference.wav');
    await fs.writeFile(path.join(output,'reference.wav'),Buffer.from(await reference.arrayBuffer()));
    for(let i=0;i<100;i++) {
      const health=await (await fetch('http://127.0.0.1:4002/health')).json();
      if(health.active===0){report.cleanup=true;break;}
      await new Promise(r=>setTimeout(r,50));
    }
    await fs.writeFile(path.join(output,'browser.json'),JSON.stringify(report,null,2)+'\n');
    report.passed = !report.error && !!(report.finished || report.intentionalDisconnect) && !!report.cleanup && !report.events.some(e=>e.type==='failure');
    await fs.writeFile(path.join(output,'browser.json'),JSON.stringify(report,null,2)+'\n');
    if(report.error || (!report.finished && !report.intentionalDisconnect) || !report.cleanup || report.events.some(e=>e.type==='failure')) throw Error('Receiver run failed; evidence preserved');
    console.log(`Decoded audio and diagnostics: ${output}`);
  } finally {await browser.close();await Promise.all(workers.map(w=>w.terminate()));}
}
run().catch(e=>{console.error(e);process.exitCode=1;});
