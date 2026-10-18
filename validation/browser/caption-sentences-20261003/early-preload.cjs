'use strict';
// Diagnostic experiment only: replace the selected scenario, not runtime code.
const path = require('node:path');
const assert = require('node:assert/strict');
const source = path.resolve(process.cwd(),'validation/task-pilot/scenarios.cjs');
const {definitions,phrases} = require(source);
const {assertUnsegmentedCaptionRows,assistantText} = require(path.resolve(process.cwd(),'validation/task-pilot/outcomes.cjs'));
phrases.captionFrontDoor = 'For order one hundred twenty four, change the delivery instructions to left in my front door.';
const selected = definitions.find(d=>d.id==='20-browser-confirmation');
selected.goal='Diagnostic: confirm as soon as the assistant mentions Confirm, retain trailing draft/save fragments';
selected.run=async h=>{
  const before=await h.dashboard();
  await h.connect({package:'captionFrontDoor'});
  await h.caption(/help check an order/i); await h.pause(1800);
  await h.play('package'); const draft=await h.draft(/front door/i);
  await h.accepted('124','delivery');
  await h.caption(/\bconfirm\b/i);
  h.evidence.checkpoints.push({kind:'diagnostic-confirm-before-caption-completion',at_ms:Date.now(),rows:await h.page.locator('#transcript p').allTextContents()});
  const confirmedAt = Date.now();
  await h.action(draft.id,'confirm');
  await h.wait(async()=>assistantText(h.evidence,confirmedAt).match(/(?:saved|updated|confirmed update|now has)[\s\S]{0,180}front door/i),'saved announcement');
  await h.pause(5500);
  const after=await h.dashboard();
  assert.equal(after.orders.find(o=>o.id==='124').version,before.orders.find(o=>o.id==='124').version+1);
  const rows = await h.page.locator('#transcript p[data-speaker="assistant"]').evaluateAll(nodes=>nodes.map(node=>node.lastChild.textContent));
  assertUnsegmentedCaptionRows(rows,assistantText(h.evidence,0));
  h.evidence.checkpoints.push({kind:'diagnostic-final-caption-rows',at_ms:Date.now(),rows});
};
