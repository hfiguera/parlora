'use strict';
(() => {
  const el = id => document.getElementById(id);
  let csrf, pending = false, proposalSignature, changeSignature, proposalAction = false;
  const node = (tag, text, className) => {
    const n = document.createElement(tag); n.textContent = text;
    if (className) n.className = className;
    return n;
  };
  const notice = (target, text, kind = 'success') => {
    target.textContent = text; target.dataset.kind = kind;
  };
  async function post(path, body) {
    let response;
    try {
      response = await fetch(path, {method: 'POST', headers: {'content-type': 'application/json', 'x-csrf-token': csrf}, body: JSON.stringify(body), signal: AbortSignal.timeout(5000)});
    } catch (_) {
      throw new Error('The outcome is unknown. Check your connection, then retry this same action.');
    }
    if (!response.ok) throw new Error(response.status === 409 ? 'This draft is no longer current. Review the order and create a new draft.' : 'The request could not be completed. Try again.');
    return response.json();
  }
  function card(order) {
    const article = node('article', '', 'order-card'); article.id = `order-${order.id}`;
    article.append(node('h3', `Order ${order.id}`));
    for (const name of ['status', 'items', 'tracking', 'instructions', 'version']) {
      const p = node('p', ''); p.dataset.field = name; article.append(p);
    }
    const form = node('form', '');
    const label = node('label', `New delivery instructions for order ${order.id}`);
    const input = node('input', ''); input.maxLength = 300; input.required = true; input.name = 'instructions';
    input.id = `instructions-${order.id}`; label.htmlFor = input.id;
    const button = node('button', 'Create review draft'); button.type = 'submit';
    const feedback = node('p', '', 'feedback'); feedback.setAttribute('role', 'status');
    form.append(label, input, button, feedback); article.append(form);
    let draftId = null, draftText = null;
    form.onsubmit = async event => {
      event.preventDefault();
      const text = input.value.trim();
      if (!text) { notice(feedback, 'Enter delivery instructions before creating a draft.', 'error'); input.focus(); return; }
      button.disabled = true; button.textContent = 'Creating draft…';
      // An uncertain HTTP response retries the same immutable operation ID.
      if (draftText !== text) { draftId = crypto.randomUUID(); draftText = text; }
      try {
        await post('/api/proposals', {id: draftId, order: order.id, instructions: text});
        draftId = draftText = null;
        notice(feedback, 'Draft created. Review it before saving.');
        const link = node('a', 'Review delivery drafts'); link.href = '#review-heading';
        feedback.append(document.createTextNode(' '), link);
        await refresh();
      } catch (error) { notice(feedback, error.message, 'error'); }
      finally { button.disabled = false; button.textContent = 'Create review draft'; }
    };
    return article;
  }
  function renderOrders(orders) {
    for (const order of orders) {
      let article = el(`order-${order.id}`);
      if (!article) { article = card(order); el('orders').append(article); }
      const values = {status: order.status, items: order.items.map(i => `${i.quantity} × ${i.name}`).join(', '), tracking: `Tracking: ${order.tracking}`, instructions: `Delivery instructions: ${order.instructions || 'None'}`, version: `Record version ${order.version}`};
      for (const [key, value] of Object.entries(values)) article.querySelector(`[data-field="${key}"]`).textContent = value;
    }
  }
  function renderProposals(proposals) {
    if (proposalAction) return; // Polling must not replace an in-flight confirmation control.
    const signature = JSON.stringify(proposals);
    if (signature === proposalSignature) return;
    proposalSignature = signature;
    const focused = document.activeElement;
    const focusedId = focused.closest('[data-proposal]')?.dataset.proposal;
    const focusedAction = focused.dataset.action;
    const count = proposals.filter(p => p.status === 'pending').length;
    el('draft-count').hidden = count === 0;
    el('draft-count').textContent = `${count} to review`;
    el('proposals').replaceChildren(...proposals.map(p => {
      const row = node('article', '', 'proposal'); row.dataset.proposal = p.id;
      const labels = {pending: 'Not saved · expires five minutes after creation', applied: 'Saved', rejected: 'Draft rejected', expired: 'Draft expired'};
      row.append(node('h3', `Order ${p.order}`), node('p', labels[p.status] || p.status, 'state'), node('p', p.instructions, 'draft-text'));
      if (p.status === 'pending') {
        const confirm = node('button', `Confirm update to order ${p.order}`, 'primary'), reject = node('button', 'Reject draft');
        for (const [button, action] of [[confirm, 'confirm'], [reject, 'reject']]) {
          button.dataset.action = action;
          button.onclick = async () => {
            if (proposalAction) return;
            proposalAction = true; confirm.disabled = reject.disabled = true;
            button.textContent = action === 'confirm' ? 'Saving…' : 'Rejecting…';
            try {
              await post(`/api/proposals/${encodeURIComponent(p.id)}/${action}`, {});
              notice(el('proposal-notice'), action === 'confirm' ? `Saved delivery instructions for order ${p.order}.` : `Draft for order ${p.order} rejected. This draft was not saved.`);
            } catch (error) { notice(el('proposal-notice'), error.message, 'error'); }
            finally {
              proposalAction = false; proposalSignature = null;
              // Preserve a useful keyboard destination when the action removes its button.
              if (document.activeElement === button || document.activeElement === document.body) el('proposal-notice').focus({preventScroll: true});
              confirm.disabled = reject.disabled = false;
              confirm.textContent = `Confirm update to order ${p.order}`; reject.textContent = 'Reject draft';
              await refresh();
            }
          };
        }
        row.append(confirm, reject);
      }
      return row;
    }));
    if (!proposals.length) el('proposals').append(node('p', 'No drafts to review. Ask to change delivery instructions, or create a draft from an order below.', 'empty'));
    if (focusedId) {
      const row = [...el('proposals').children].find(p => p.dataset.proposal === focusedId);
      const replacement = row && [...row.querySelectorAll('button')].find(b => b.dataset.action === focusedAction);
      (replacement || el('proposal-notice')).focus({preventScroll: true});
    }
  }
  async function refresh() {
    if (pending) return;
    pending = true;
    try {
      const response = await fetch('/api/orders', {cache: 'no-store', signal: AbortSignal.timeout(5000)});
      if (!response.ok) throw new Error('Could not load orders.');
      const data = await response.json(); csrf = data.csrf;
      renderOrders(data.orders); renderProposals(data.proposals);
      const signature = JSON.stringify(data.changes);
      if (signature !== changeSignature) {
        changeSignature = signature;
        el('changes').replaceChildren(...data.changes.map(c => node('p', `Order ${c.order} · version ${c.version} · ${c.instructions}`)));
        if (!data.changes.length) el('changes').append(node('p', 'No saved changes yet. Confirmed delivery updates will appear here.', 'empty'));
      }
      const metrics = m => `evaluations ${m.calls}, cache hits ${m.hits}, uncertain ${m.uncertain}, errors ${m.errors}, skipped obsolete ${m.skipped}, stale at return ${m.stale}, deferred ${m.deferred}`;
      const latest = data.interpretation.sessions.at(-1);
      el('interpreter').textContent = `${latest ? `Your latest session (${latest.closed ? 'closed' : 'active'}): ${metrics(latest.metrics)}. ` : ''}Application totals: ${metrics(data.interpretation.application)}.`;
      if (el('order-notice').textContent) notice(el('order-notice'), '');
      el('retry-orders').hidden = true;
    } catch (_) {
      notice(el('order-notice'), 'Could not refresh orders. Displayed records may be out of date. Check your connection and retry.', 'error');
      el('retry-orders').hidden = false;
    } finally { pending = false; }
  }
  el('retry-orders').onclick = refresh;
  refresh();
  const timer = setInterval(refresh, 2000);
  window.addEventListener('pagehide', () => clearInterval(timer));
})();
