'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const guide = fs.readFileSync(path.join(__dirname, '../../docs/browser-channel.md'), 'utf8');
const html = guide.match(/<!-- browser-client.html -->\s*```html\n([\s\S]*?)\n```/)[1];
const script = html.match(/<script>\n([\s\S]*?)\n<\/script>/)[1];
const settle = () => new Promise(resolve => setImmediate(resolve));
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return {promise, resolve, reject};
}
function harness(options = {}) {
  const elements = Object.fromEntries(['connect', 'disconnect', 'status', 'speaker']
    .map(id => [id, {disabled: id === 'disconnect', textContent: '', srcObject: null, play: async () => {}}]));
  const tracks = [], peers = [], sockets = [], intervals = new Map(), listeners = {};
  function microphone() {
    const track = {enabled: true, stopped: false, stop() { this.stopped = true; }};
    tracks.push(track);
    return {getAudioTracks: () => [track], getTracks: () => [track]};
  }
  class Peer {
    constructor() { this.applied = []; this.remoteDescription = null; peers.push(this); }
    addTrack(track) { this.track = track; }
    async createOffer() {
      if (options.offer) await options.offer.promise;
      return {type: 'offer', sdp: 'test-offer'};
    }
    async setLocalDescription() {
      this.onicecandidate({candidate: {toJSON: () => ({candidate: 'local', sdpMid: '0', sdpMLineIndex: 0})}});
      this.onicecandidate({candidate: null});
    }
    async setRemoteDescription(answer) {
      if (options.answer) await options.answer.promise;
      this.remoteDescription = answer;
    }
    async addIceCandidate(candidate) {
      assert.ok(this.remoteDescription, 'candidate must not overtake the answer');
      this.applied.push(candidate);
    }
    close() { this.connectionState = 'closed'; this.onconnectionstatechange?.(); }
  }
  class Socket {
    static OPEN = 1;
    constructor(url) { this.url = url; this.readyState = 0; this.sent = []; sockets.push(this); }
    open() { this.readyState = 1; this.onopen(); }
    send(data) { this.sent.push(JSON.parse(data)); }
    close() { this.readyState = 3; this.onclose?.(); }
    receive(message) { this.onmessage({data: JSON.stringify(message)}); }
  }
  vm.runInNewContext(script, {
    document: {querySelector: selector => elements[selector.slice(1)]},
    navigator: {mediaDevices: {getUserMedia: async () => {
      if (options.permission) await options.permission.promise;
      return microphone();
    }}},
    RTCPeerConnection: Peer, WebSocket: Socket, MediaStream: class {},
    location: {protocol: 'https:', host: 'voice.example'},
    window: {addEventListener: (name, fn) => { listeners[name] = fn; }},
    setInterval: (fn, ms) => { const id = Symbol(); intervals.set(id, {fn, ms}); return id; },
    clearInterval: id => intervals.delete(id)
  });
  return {elements, peers, sockets, tracks, intervals, listeners};
}

test('copied client waits for attached, sends offer before local ICE, and gates speech on ready', async () => {
  const h = harness();
  await h.elements.connect.onclick();
  const socket = h.sockets[0]; socket.open();
  assert.equal(socket.url, 'wss://voice.example/voice');
  assert.deepEqual(socket.sent, []);
  assert.equal(h.tracks[0].enabled, false);
  socket.receive({type: 'attached', session_id: 'first'});
  await settle();
  assert.deepEqual(socket.sent, [
    {type: 'offer', sdp: 'test-offer'},
    {type: 'candidate', candidate: {candidate: 'local', sdpMid: '0', sdpMLineIndex: 0}}
  ]);
  assert.equal(h.tracks[0].enabled, false);
  socket.receive({type: 'ready'}); await settle();
  assert.equal(h.tracks[0].enabled, true);
  assert.equal(h.elements.status.textContent, 'Ready. You can speak.');
  h.elements.disconnect.onclick();
});

test('server ICE before and during the async answer is applied in order after the description', async () => {
  const answer = deferred(), h = harness({answer});
  await h.elements.connect.onclick();
  const socket = h.sockets[0]; socket.open();
  socket.receive({type: 'attached'}); await settle();
  socket.receive({type: 'candidate', candidate: {candidate: 'early'}});
  socket.receive({type: 'answer', sdp: 'test-answer'});
  socket.receive({type: 'candidate', candidate: {candidate: 'later'}});
  await settle();
  assert.deepEqual(h.peers[0].applied, []);
  answer.resolve(); await settle();
  assert.deepEqual(h.peers[0].applied.map(candidate => candidate.candidate), ['early', 'later']);
  h.elements.disconnect.onclick();
});

test('five-second keepalives and socket closure release the microphone, peer, and timer', async () => {
  const h = harness(); await h.elements.connect.onclick();
  const socket = h.sockets[0]; socket.open();
  const [timer] = h.intervals.values();
  assert.equal(timer.ms, 5000); timer.fn();
  assert.deepEqual(socket.sent, [{type: 'ping'}]);
  socket.close();
  assert.equal(h.intervals.size, 0);
  assert.equal(h.tracks[0].stopped, true);
  assert.equal(h.peers[0].connectionState, 'closed');
  assert.equal(h.elements.connect.disabled, false);
  assert.equal(h.elements.disconnect.disabled, true);
});

test('permission denial creates no session and restores the connect button', async () => {
  const permission = deferred(), h = harness({permission});
  const connecting = h.elements.connect.onclick();
  permission.reject(new Error('Permission denied')); await connecting;
  assert.equal(h.sockets.length, 0);
  assert.equal(h.elements.connect.disabled, false);
  assert.match(h.elements.status.textContent, /microphone permission/);
});

test('disconnect while permission is pending stops the late microphone without opening a socket', async () => {
  const permission = deferred(), h = harness({permission});
  const connecting = h.elements.connect.onclick();
  h.elements.disconnect.onclick(); permission.resolve(); await connecting;
  assert.equal(h.tracks[0].stopped, true);
  assert.equal(h.sockets.length, 0);
  assert.equal(h.elements.status.textContent, 'Disconnected.');
});

test('a late offer from a disconnected call cannot send signaling or disrupt its replacement', async () => {
  const offer = deferred(), h = harness({offer});
  await h.elements.connect.onclick();
  const oldSocket = h.sockets[0]; oldSocket.open();
  oldSocket.receive({type: 'attached'}); await settle();
  h.elements.disconnect.onclick();
  await h.elements.connect.onclick(); h.sockets[1].open();
  offer.resolve(); await settle();
  assert.deepEqual(oldSocket.sent, [{type: 'disconnect'}]);
  assert.equal(h.tracks[0].stopped, true);
  assert.equal(h.tracks[1].stopped, false);
  assert.equal(h.elements.connect.disabled, true);
  h.listeners.pagehide();
  assert.equal(h.tracks[1].stopped, true);
  assert.equal(h.intervals.size, 0);
});

test('adapter failure and malformed signaling both clean up an established socket', async () => {
  for (const message of [{type: 'event', event: 'failed'}, null]) {
    const h = harness(); await h.elements.connect.onclick(); h.sockets[0].open();
    if (message) h.sockets[0].receive(message);
    else h.sockets[0].onmessage({data: 'invalid-json'});
    await settle();
    assert.equal(h.tracks[0].stopped, true);
    assert.equal(h.peers[0].connectionState, 'closed');
    assert.equal(h.intervals.size, 0);
    assert.equal(h.elements.connect.disabled, false);
  }
});
