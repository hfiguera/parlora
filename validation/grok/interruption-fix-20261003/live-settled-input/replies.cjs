'use strict';
// These are bounded checks for fixture facts, not a general semantic judge.
function normalize(text) {return text.toLowerCase().replace(/[’‘]/g,"'").replace(/\s+/g,' ').trim();}
function checkReply(kind,text) {
  text=normalize(text);
  if(kind==='empty-instructions') {
    return /(?:no|without) (?:saved |special |delivery |any )*instructions/.test(text) ||
      /(?:don't see|do not see|don't have|do not have|aren't|are not|doesn't have|does not have|haven't got|have not got) any (?:saved |delivery |special )*instructions/.test(text) ||
      /instructions (?:are |have been |were )?(?:not (?:set|saved|specified)|empty|none)/.test(text) ||
      /(?:nothing|none) (?:listed|saved|recorded|on file|set|specified)/.test(text);
  }
  if(kind==='not-found') {
    return /(?:order[^.!?]{0,55}(?:not found|wasn't found|was not found|isn't found|is not found|isn't (?:showing|appearing))|(?:can't find|cannot find|couldn't find|could not find|couldn't locate|could not locate|wasn't able to find|was not able to find|not finding|not seeing|don't see|do not see|don't find|do not find) (?:(?:an |any |that |the )?order\b|that one\b)|no (?:matching )?order\b)/.test(text);
  }
  if(kind==='browser-confirmation') {
    // A mention or a negated instruction is not an actionable confirmation step.
    return text.split(/[.!?]+/).some(clause =>
      !/\b(?:don't|do not|never|no need|needn't)\b[^.!?]{0,55}\b(?:click|press|tap|select|hit|use|confirm)\b/.test(clause) && (
        /\b(?:click|press|tap|select|hit|use)\b[^.!?]{0,70}\bconfirm\b/.test(clause) ||
        /\bplease review\b[^.!?]{0,70}\b(?:page|browser|screen)\b\s+and confirm\b[^.!?]{0,20}\bsave\b/.test(clause) ||
        /\b(?:need to|must|have to|please|you can)\b[^.!?]{0,55}\bconfirm\b[^.!?]{0,55}\b(?:page|browser|button|screen)\b/.test(clause)));
  }
  if(kind==='saved-reception') {
    const clauses = text.split(/[.!?]+/).map(clause => clause.trim());
    const saved = clause => /\b(?:saved|updated)\b/.test(clause) &&
      !/\bdraft\b/.test(clause) &&
      !/\b(?:not|never|haven't|hasn't|isn't|wasn't)\b[^.!?]{0,30}\b(?:saved|updated)\b/.test(clause) &&
      !/\b(?:will|can|could|would|once|after)\b[^.!?]{0,40}\b(?:saved|updated)\b/.test(clause);
    // Accept a complete save claim followed by its explicit resulting instruction.
    // An earlier draft or a later unfinished claim cannot supply the destination.
    return clauses.some((clause, i) => saved(clause) && (
      /\breception\b/.test(clause) ||
      (/^(?:(?:the|your) (?:delivery )?instructions? (?:is|are|says?)\b|order 124 now has (?:the )?delivery instructions?\b)/.test(clauses[i + 1] || '') &&
        /\breception\b/.test(clauses[i + 1]))));
  }
  throw new Error('Unknown reply check: '+kind);
}
module.exports={checkReply};
