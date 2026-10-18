---
"@context": https://schema.org
"@type": TechArticle
"@id": https://www.twilio.com/docs/voice/sdks/javascript/twilioaudioprocessor#article
headline: "Voice JavaScript SDK: AudioProcessor"
description: Reference documentation for AudioProcessor, an API that provides access to the audio input stream and the ability to process or analyze the stream when working with Programmable Voice and JavaScript.
url: https://www.twilio.com/docs/voice/sdks/javascript/twilioaudioprocessor
inLanguage: en
dateModified: 2026-03-09T18:47:22.000Z
author:
  "@type": Organization
  name: Twilio Developer Education Team
publisher:
  "@type": Organization
  name: Twilio
---

# Voice JavaScript SDK: AudioProcessor

You can add a local `AudioProcessor` to the SDK to access and process the audio input stream before sending it to Twilio. Similarly, you can add a remote `AudioProcessor` to access and process the audio output stream before it is rendered on the speaker.

* To add a processor, implement the `AudioProcessor` interface and use [`device.audio.addProcessor`](/docs/voice/sdks/javascript/twiliodevice/device-audio#deviceaudioaddprocessorprocessor).
* To remove a processor, use [`device.audio.removeProcessor`](/docs/voice/sdks/javascript/twiliodevice/device-audio#deviceaudioremoveprocessorprocessor).
* To specify whether the processor is local or remote, use the optional `isRemote` parameter.

Use cases include:

* Background noise removal using a noise cancellation library of your choice
* Music playback when putting the call on hold
* Audio filters
* AI audio classification
* ... and more!

**Example:**

The following example demonstrates how to utilize AudioProcessor APIs to use background music for local audio instead of using a microphone.

```javascript
import { AudioProcessor, Device } from '@twilio/voice-sdk';

let audioContext;

class BackgroundAudioProcessor implements AudioProcessor {

 private audioContext: AudioContext;
 private background: MediaElementAudioSourceNode;
 private destination: MediaStreamAudioDestinationNode;

 constructor() {
   if (!audioContext) {
     audioContext = new AudioContext();
   }
   this.audioContext = audioContext;
 }

 async createProcessedStream(stream: MediaStream): Promise<MediaStream> {
   // Create the source node
   const audioEl = new Audio('/background.mp3');
   audioEl.addEventListener('canplaythrough', () => audioEl.play());
   this.background = this.audioContext.createMediaElementSource(audioEl);

   // Create the destination node and connect the source node
   this.destination = this.audioContext.createMediaStreamDestination();
   this.background.connect(this.destination);

   // Return the resulting MediaStream
   return this.destination.stream;
 }

 async destroyProcessedStream(stream: MediaStream): Promise<void> {
   // Cleanup
   this.background.disconnect();
   this.destination.disconnect();
 }
}
// Construct a device object, passing your own token and desired options
const device = new Device(token, options);

// Construct the AudioProcessor
const processor = new BackgroundAudioProcessor();

// Add the local processor
await device.audio.addProcessor(processor, false);
// Remove the local processor later
// await device.audio.removeProcessor(processor, false);

// Or add the remote processor
// await device.audio.addProcessor(processor, true);
// Remove the remote processor later
// await device.audio.removeProcessor(processor, true);
```

## Method Reference

### audioProcessor.createProcessedStream(stream)

Called by the SDK whenever the active input audio stream is updated. Use this method to initiate your audio processing pipeline and return the resulting audio stream in a Promise\<MediaStream>.

This method has one argument which represents the current input audio stream. This is the MediaStream object from the input device, such as the microphone. You can process or analyze this stream and create a new stream that will be sent to Twilio.

### audioProcessor.destroyProcessedStream(stream)

Called by the SDK after the original input audio stream and the processed stream has been destroyed. The stream is considered destroyed when all of its tracks are stopped and its references in the SDK are removed. This method is called whenever the current input stream is updated. Use this method to run any necessary teardown routines needed by your audio processing pipeline and return a Promise\<void> representing the result of the teardown process.

This method has one argument which represents the destroyed processed audio stream.
