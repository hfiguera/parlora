'use strict';
const fs = require('node:fs');
const path = require('node:path');
const {hash} = require('./report.cjs');
function files(directory, prefix='') {
  if(!fs.existsSync(directory)) return [];
  return fs.readdirSync(directory,{withFileTypes:true}).flatMap(e=>{
    const name=path.join(prefix,e.name);
    if(['target','test-audio','__pycache__'].includes(e.name)) return [];
    return e.isDirectory()?files(path.join(directory,e.name),name):[name];
  });
}
function verifyConsumer(root, consumer) {
  const sources={};
  for(const [canonical,installed,areas] of [
    [path.join(root,'examples/order_desk'),consumer,['lib','config','priv','test','mix.exs','mix.lock']],
    [root,path.join(consumer,'vendor/parlora'),['lib','native','mix.exs','mix.lock','rust-toolchain.toml']]
  ]) {
    for(const area of areas) {
      const entry=path.join(canonical,area);
      const names=fs.statSync(entry).isDirectory()?files(entry).map(f=>path.join(area,f)):[area];
      for(const name of names) {
        const expected=path.join(canonical,name),actual=path.join(installed,name);
        if(!fs.existsSync(actual) || hash(expected)!==hash(actual)) throw new Error('Stale consumer source: '+path.relative(consumer,actual)+'. Build a fresh consumer.');
        sources[path.relative(consumer,actual)]=hash(actual);
      }
      if(fs.statSync(entry).isDirectory()) {
        const extra=files(path.join(installed,area)).filter(f=>!names.includes(path.join(area,f)));
        if(extra.length) throw new Error('Unexpected consumer source: '+area+'/'+extra[0]);
      }
    }
  }
  return sources;
}
module.exports={verifyConsumer};
