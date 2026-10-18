'use strict';
const test=require('node:test');const assert=require('node:assert/strict');const {checkReply}=require('./replies.cjs');
test('observed valid negative results accept natural wording',()=>{
  for(const text of ["I don't see any saved delivery instructions for that one.","There aren't any delivery instructions saved for order one twenty four.","Order 124 has no delivery instructions."])
    assert(checkReply('empty-instructions',text),text);
  for(const text of ["I'm not finding order nine nine nine.","Order 999 wasn't found here.","I wasn’t able to find order nine-nine-nine.","I don’t see an order with that number.","I can’t find that one here.","That order isn’t found for this demo customer."])
    assert(checkReply('not-found',text),text);
});
test('unrelated uncertainty and positive facts cannot pass a negative-result check',()=>{
  for(const text of ["I don't see", "I don't see a problem with that order", "Order 999 is out for delivery", "I can find order 999"])
    assert.equal(checkReply('not-found',text),false,text);
  for(const text of ["Delivery instructions: leave it at reception", "I don't see the delivery date", "Checking instructions now"])
    assert.equal(checkReply('empty-instructions',text),false,text);
});
