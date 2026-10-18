---
"@context": https://schema.org
"@type": TechArticle
"@id": https://www.twilio.com/docs/voice/media-streams#article
headline: Media Streams Overview
description: Receive raw audio streams from live phone calls over WebSockets using Twilio Media Streams for AI/ML transcription and self-service automation.
url: https://www.twilio.com/docs/voice/media-streams
inLanguage: en
dateModified: 2026-06-25T15:34:43.000Z
author:
  "@type": Organization
  name: Twilio Developer Education Team
publisher:
  "@type": Organization
  name: Twilio
---

# Media Streams Overview

Learn how to use Twilio Media Streams to capture, transmit, and receive raw audio from live voice calls over WebSockets in near real-time. This feature allows you to access both inbound and outbound audio tracks for immediate external processing. You can use this guide to implement self-service automation, create inbound contact centers, create outbound contact centers, deploy AI agents, and create AI/ML transcriptions.

See [Related reference documentation](#related-reference-documentation) to learn more about the TwiML and API resources used in this guide.

## Media Streams overview

Media Streams provides access to the raw audio from a Programmable Voice call by streaming it over WebSockets to a destination you specify. This enables use cases such as real-time transcriptions, sentiment analysis, voice authentication, and more. You can also stream raw audio into a Twilio Voice call from another application, enabling conversational Interactive Voice Response (IVR) or real-time interactions with an AI chatbot.

> \[!NOTE]
>
> You can use [Media Streams][regional-availability] in the Ireland (`IE1`) and Australia (`AU1`) [Regions][twilio-regions]. To set up Media Streams with these regions, follow the guides for non-US [outbound][non-us-outgoing] and [inbound][non-us-incoming] calls. The [default region][default-region] remains `US1`.

[non-us-outgoing]: /docs/global-infrastructure/create-an-outbound-call-via-rest-api-in-a-non-us-twilio-region

[non-us-incoming]: /docs/global-infrastructure/inbound-call-processing

[twilio-regions]: /docs/global-infrastructure/understanding-twilio-regions

[default-region]: /docs/global-infrastructure/understanding-twilio-regions#use-the-default-twilio-region

[regional-availability]: /docs/global-infrastructure/regional-product-and-feature-availability

To get started with Media Streams, first make sure you're familiar with making and receiving voice calls with Twilio. If this is your first time building with Twilio Programmable Voice, complete one of the [Voice quickstarts](/docs/voice/quickstart).

Before you build with Media Streams, decide whether you need a unidirectional or bidirectional stream. The sections below explain the differences between each option and provide links to helpful docs and resources.

## Unidirectional Media Streams

In a unidirectional Media Stream, your WebSocket application receives the call's audio but can't send audio back to Twilio for playback.

With unidirectional Media Streams, you can receive the inbound audio [track](/docs/voice/twiml/stream#track) (the audio that is incoming to Twilio), the outbound audio track (the audio that Twilio is generating on the call), or both tracks.

DTMF isn't supported with unidirectional streams.

Start a unidirectional stream with the `<Start><Stream>` TwiML verb or through the [Stream resource](/docs/voice/api/stream-resource) REST API.

If you use TwiML for the stream, Twilio executes `<Start><Stream>`, which initiates the audio stream with your WebSocket server, and then executes the next TwiML instruction you provide.

You can stop a unidirectional Media Stream using `<Stop><Stream>` or via the [Stream resource](/docs/voice/api/stream-resource#update-a-stream-resource).

### Resources for unidirectional Media Streams

Use the following resources to build your unidirectional Media Streams application:

* [\<Stream> TwiML Reference](/docs/voice/twiml/stream)
* [Stream Resource API Reference](/docs/voice/api/stream-resource)
* [WebSocket Messages](/docs/voice/media-streams/websocket-messages)
  * Learn about the format and contents of the WebSocket messages that Twilio sends to your server

Sample applications are available in the following languages:

* [Node.js](https://github.com/twilio/media-streams/tree/master/node/basic)
* [Python](https://github.com/twilio/media-streams/tree/master/python/basic)
* [Java](https://github.com/twilio/media-streams/tree/master/java/basic)

## Bidirectional Media Streams

Bidirectional Media Streams are those in which your WebSocket application both receives audio from Twilio and can send audio to Twilio, which is then played on the Call. An example use case for bidirectional Media Streams is to facilitate a real-time voice conversation with an AI assistant.

With bidirectional Media Streams, you can only receive the inbound [track](/docs/voice/twiml/stream#track).

[DTMF](/docs/voice/media-streams/websocket-messages#dtmf-message) is supported with bidirectional Media Streams only in the inbound direction, from Twilio toward your media server. Sending DTMF outbound from your media server toward Twilio is not supported.

To start a bidirectional Media Stream, use `<Connect><Stream>`. These TwiML instructions block subsequent TwiML instructions unless the WebSocket connection is disconnected.

You *can't* use the Stream resource to start a bidirectional Media Stream.

You can stop a bidirectional Media Stream by closing the WebSocket connection from your server or by ending the Call.

### Resources for bidirectional Media Streams

Check out the following resources to help you build your bidirectional Media Streams application:

* [\<Stream> TwiML Reference](/docs/voice/twiml/stream)
* [WebSocket Messages](/docs/voice/media-streams/websocket-messages)
  * The ["Send WebSocket messages to Twilio" section](/docs/voice/media-streams/websocket-messages#send-websocket-messages-to-twilio) covers how to send audio back to Twilio.
* [Basic bidirectional stream sample application](https://github.com/twilio/media-streams/tree/master/node/connect-basic)

## Limits

For unidirectional Streams, you can stream up to four [tracks](/docs/voice/twiml/stream#track) at a time on a Call. This four-track limit is shared with other Twilio features that fork audio, including [SIPREC](/docs/voice/twiml/siprec), [Real-Time Transcription](/docs/voice/twiml/transcription), and [Answering Machine Detection](/docs/voice/answering-machine-detection). Plan your fork budget across all active features on the call. See [Forked Audio Streams](/docs/voice/programmable-voice-limits#forked-audio-streams) for the full breakdown of fork costs and common combinations.

For bidirectional Streams, you can have only one Stream per Call.

Each Media Stream is associated with one WebSocket connection.

## Communicate with Twilio's media servers

Your Media Streams application must be able to communicate with Twilio.

Configure your firewall rules to allow secure WebSocket connections (TCP port 443) from Twilio to your WebSocket servers from any public IP address.

You must also configure your application to validate the `X-Twilio-Signature` header. This is how your application verifies that a Media Stream is coming from an authentic Twilio source. Learn more on the [General Usage - Security page](/docs/usage/security#validating-requests).

## Use cases for Media Streams with Twilio Programmable Voice

This guide covers a feature that can support the following use cases:

### Create self-service automation with Twilio Programmable Voice

You can use the feature in this guide to build intelligent, interactive voice responses that understand spoken intent dynamically. By streaming raw call audio to your server, you can process user voice inputs with custom speech recognition models to fulfill requests automatically.

To learn more advanced features that you can use with self-service automation, see [Voice self-service automation](/docs/voice/guides/self-service-automation).

### Create an inbound contact center with Twilio Programmable Voice

You can use the feature in this guide to optimize live call handling workflows for support centers. Real-time media streaming enables backend software to monitor caller audio, providing immediate context or assisting with automated verification steps before routing the call to an agent.

To learn more advanced features that you can use with inbound contact centers, see [Voice inbound contact center](/docs/voice/guides/inbound-call-center).

### Create an outbound contact center with Twilio Programmable Voice

You can use the feature in this guide to enrich outreach quality and tracking. Outbound calls can stream their active audio directly to analytical infrastructure to monitor script compliance or measure engagement parameters programmatically.

To learn more advanced features that you can use with outbound contact centers, see [Voice outbound contact center](/docs/voice/guides/outbound-call-center).

### Deploy AI agents with Twilio Programmable Voice

You can use the feature in this guide to establish bidirectional conversations between human callers and conversational artificial intelligence models. Real-time audio streaming feeds backend AI engines, which can immediately generate voice responses and stream them back to the caller over WebSockets.

To learn more advanced features that you can use with AI agents, see [Voice AI agents](/docs/voice/guides/ai-agents).

### Create transcriptions for AI or ML with Twilio Programmable Voice

You can use the feature in this guide to capture the precise audio of your calls for immediate machine-driven evaluation. Streaming the raw audio to machine learning pipelines supports automated post-call summarization, live language translation, or continuous sentiment profiling.

To learn more advanced features that you can use with AI or ML transcription, see [Voice AI and ML transcription](/docs/voice/guides/ai-ml-transcription).

## Next steps

Explore the following guides to build on what you've learned in this guide:

* [Consume a real-time Media Stream using WebSockets, Python, and Flask](/docs/voice/tutorials/consume-real-time-media-stream-using-websockets-python-and-flask): Set up a practical developer environment to analyze raw call audio files via Python.
* [Connect Twilio with your Dialogflow Agent](/docs/voice/twiml/stream/connect-to-dialogflow): Integrate automated natural language processing into your active voice channels.
* [Sample application GitHub repo](https://github.com/twilio/media-streams): Explore the sample application that demonstrates how to implement Media Streams.

## Related reference documentation

Find reference documentation for the topics on this page.

* [TwiML Voice: `<Stream>`](/docs/voice/twiml/stream)
* [Stream resource](/docs/voice/api/stream-resource)
