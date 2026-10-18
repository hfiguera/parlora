'use strict';
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const root=process.cwd();
// Freeze the historical callback so this investigation remains reproducible
// after the current browser renderer is fixed.
const baseline='63e34659dc4a06abd6c4c9a726df134a3f183375';
const gitFile=file=>require('node:child_process').execFileSync('git',['show',`${baseline}:${file}`],{encoding:'utf8'});
const source=gitFile('validation/browser/captions_test.cjs');
const historicalFs={...fs,readFileSync(file,...options){
  return file===path.join(root,'examples/order_desk/priv/browser/voice.js')
    ? gitFile('examples/order_desk/priv/browser/voice.js') : fs.readFileSync(file,...options);
}};
const scope={fs:historicalFs,path,vm,__dirname:path.join(root,'validation/browser')};
vm.runInNewContext(source.slice(source.indexOf('function harness()'),source.indexOf("test('separate"))+'; this.make = harness;',scope);
const h=scope.make();
const inputs=[
 {speaker:'assistant',delta:"I have a draft for order 124. Press Confirm to save it.",start_ms:1000,end_ms:10000},
 {speaker:'assistant',delta:"Saying yes won't save it.",start_ms:11800,end_ms:13200},
 {speaker:'assistant',delta:" Just to note, order 124 has saved the instruction: left in my front door.",start_ms:13400,end_ms:17000}
];
h.send(inputs[0]); const before=h.rows().length;
for(const p of inputs.slice(1)) h.send(p);
const rows=h.rows();
const rowCountGuard=rows.length>before;
const regexGuard=!rows.some(text=>/confirm/i.test(text)&&/(?:has been|have been|were) (?:saved|updated)/i.test(text));
assert.equal(rows.length,2);assert(rows[1].includes("Saying yes won't save it")&&rows[1].includes('has saved'));
assert(rowCountGuard&&regexGuard);
const report={classification:'Deterministic synthetic reproduction using the historical caption callback; timestamps are chosen fixture inputs, not recovered from the manual call',sources:{head:baseline},inputs,rows,draftToReminderGapMs:1800,reminderToSaveGapMs:200,existingRegressionGuards:{rowCountGuard,regexGuard},result:'Main draft is split from its reminder; reminder merges with save; both historical live regression guards accept this output'};
if (!process.argv[2]) throw new Error('Usage: node replay.cjs NEW_REPORT.json');
fs.writeFileSync(process.argv[2],JSON.stringify(report,null,2)+'\n',{flag:'wx'});console.log(JSON.stringify(report,null,2));
