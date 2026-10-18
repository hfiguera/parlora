'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {checkReply}=require('./replies.cjs');
const {assistantText,assertUnsegmentedCaptionRows,resultBoundary,assessReply,expectReply}=require('./outcomes.cjs');
const {resultDelivered}=require('../acceptance/delivery.cjs');
test('unconfirmed Gemini delivery is eligible without weakening providers with acknowledgments',()=>{
  const job={delivery:'unconfirmed'};
  assert.equal(resultDelivered({status:{'context_acknowledgment?':false}},job),true);
  assert.equal(resultDelivered({status:{'context_acknowledgment?':true}},job),false);
  assert.equal(resultDelivered({status:{}},job),false);
  assert.equal(resultDelivered({status:{'context_acknowledgment?':false}},{delivery:'awaiting_provider'}),false);
});
test('correct backend data cannot excuse wrong or contradictory spoken facts',()=>{
  assert.equal(assessReply('Order 123 has one desk lamp.',/desk lamp/i,['123'],'124').passed,false);
  assert.equal(assessReply('Order 124 is not out for delivery.',/out for delivery/i,['124'],'124').passed,false);
  assert.equal(assessReply('One desk lamp.',/desk lamp/i,[],'124').passed,true);
});
test('the human-call unsupported today answer fails while grounded status and supplied estimates pass',()=>{
  for (const date of ['today', 'tomorrow', 'Friday', 'this afternoon']) {
    const result = assessReply(`Order 124 is out for delivery ${date}.`, /out for delivery/i, ['124'], '124');
    assert.equal(result.passed, false);
    assert.equal(result.unsupported_timing, true);
  }
  assert.equal(assessReply('Order 124 is out for delivery. No delivery date is provided.', /out for delivery/i, ['124'], '124').passed, true);
  assert.equal(assessReply('Order 123 has shipped and is expected Friday.', /expected Friday/i, ['123'], '123').passed, true);
});
test('completion boundary belongs to the current operation and excludes earlier correct-looking captions',()=>{
  const evidence={events:[
    {event:'request_completed',request_id:'old',observed_at_ms:1},
    {type:'transcript',observed_at_ms:2,payload:{speaker:'assistant',delta:'One desk lamp.'}},
    {event:'request_completed',request_id:'new',observed_at_ms:3},
    {type:'transcript',observed_at_ms:4,payload:{speaker:'user',delta:'One desk lamp.'}},
    {type:'transcript',observed_at_ms:5,payload:{speaker:'assistant',delta:'Checking.'}}]};
  const state={status:{jobs:{old:{'current?':false,delivery:'accepted'},new:{'current?':true,delivery:'accepted'}}},
    jobs:{old:{input:{order:'124',operation:'status'}},new:{input:{order:'124',operation:'items'}}}};
  const since=resultBoundary(evidence,state,'124','items');
  assert.equal(since,3);assert.equal(assistantText(evidence,since),'Checking.');
  assert.throws(()=>resultBoundary(evidence,state,'123','items'),/No accepted current/);
});
test('confirmation requires an instruction rather than merely mentioning a button or claiming success',()=>{
  assert(checkReply('browser-confirmation', 'Please review the instructions on the page and confirm to save them.'));
  assert.equal(checkReply('browser-confirmation', 'Please review the instructions on the page and do not confirm to save them.'), false);
  for(const text of ['Click Confirm on the page to save it.','Please press the Confirm button.','You need to confirm on the browser page.'])
    assert(checkReply('browser-confirmation',text),text);
  for(const text of ['Confirmed.','There is a button in the browser.','I saved it.','Your order is on the page.', 'Do not click Confirm on the page.', 'You do not need to confirm in the browser.'])
    assert.equal(checkReply('browser-confirmation',text),false,text);
});
test('caption separation rejects the actual manual wording without relying on incidental row counts',()=>{
  const reminder = "Saying yes won't save it. ";
  const saved = 'Just to note, order 124 has saved the instruction: left in my front door.';
  assert.throws(()=>assertUnsegmentedCaptionRows([reminder+saved],reminder+saved),/multiple sentences/);
  assertUnsegmentedCaptionRows([reminder,saved],reminder+saved);
  assert.throws(()=>assertUnsegmentedCaptionRows([reminder.trim(),saved],reminder+saved),/lost or changed/);
  assertUnsegmentedCaptionRows(['The confirmed update is visible. ', 'Order 124 now has the instructions.'],
    'The confirmed update is visible. Order 124 now has the instructions.');
});
test('save announcement requires a completed save and the expected destination',()=>{
  assert(checkReply('saved-reception', `That's saved. Order 124 now has the delivery instruction, "leave the package at reception."`));
  assert(checkReply('saved-reception', 'Order one twenty-four is saved. The instruction is, leave the package at reception.'));
  assert.equal(checkReply('saved-reception', `That's not saved. Order 124 now has the delivery instruction, "leave the package at reception."`), false);
  assert.equal(checkReply('saved-reception', `That's saved. A draft for order 124 says leave the package at reception.`), false);
  for(const text of ['Saved your instructions: leave the package at reception.','Your delivery instructions were updated to reception.', "A draft says reception. It's saved for order 124: leave the package at reception."])
    assert(checkReply('saved-reception',text),text);
  for(const text of ['Reception draft created.','Saved it at the neighbor.','Reception instructions are not saved.',"Reception will be saved after you confirm.",
    "A draft for order 124 says: leave the package at reception. To save it, open the page, check the exact order and text, and press Confirm. It's saved for order 124:"])
    assert.equal(checkReply('saved-reception',text),false,text);
});
function harness(text,numbers) {
  return {evidence:{events:[{type:'transcript',observed_at_ms:Date.now()-2000,payload:{speaker:'assistant',delta:text}}],checkpoints:[]},
    state:async()=>({}),wait:async(fn,label)=>{if(!await fn())throw new Error('Timed out: '+label);},
    page:{url:()=> 'http://127.0.0.1/',request:{post:async()=>({status:()=>200,json:async()=>({numbers})})}}};
}
test('reply observer retains incorrect and missing-answer failures for reporting',async()=>{
  const wrong=harness('Order 123 has one desk lamp.',['123']);
  await assert.rejects(expectReply(wrong,{since:0,pattern:/desk lamp/i,target:'124',label:'items'}),/incorrect-answer/);
  assert.deepEqual(wrong.evidence.checkpoints[0].wrong_orders,['123']);
  assert.equal(wrong.evidence.checkpoints[0].status,'failed');
  const missing=harness('There is a button.',[]);
  await assert.rejects(expectReply(missing,{since:0,pattern:'browser-confirmation',target:'124',label:'confirmation'}),/missing-answer/);
  assert.equal(missing.evidence.checkpoints[0].status,'failed');
});
