class Capture extends AudioWorkletProcessor {
  process(inputs, outputs) {
    const audio = inputs[0]?.[0];
    if (audio) { this.port.postMessage({samples: audio.slice(), at: currentTime, frame: currentFrame}); outputs[0]?.[0]?.set(audio); }
    return true;
  }
}
registerProcessor('capture', Capture);
