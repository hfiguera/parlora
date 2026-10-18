> ## Documentation Index
> Fetch the complete documentation index at: https://developers.telnyx.com/llms.txt
> Use this file to discover all available pages before exploring further.

# Stream call media over WebSocket

> AsyncAPI specification for the Telnyx Media Streaming WebSocket connection.
Media Streaming forks call media and delivers it to a customer-provided WebSocket URL configured through Call Control using `stream_url`. Telnyx opens the WebSocket connection, sends lifecycle and media frames, and can receive bidirectional media playback commands from the connected application.

## Connection Flow
1. Start media streaming with a Call Control command and provide `stream_url`.
2. Telnyx opens a WebSocket connection to the configured `stream_url`.
3. Telnyx sends a `connected` frame, followed by a `start` frame that identifies the call and media format.
4. Telnyx sends `media` frames with base64-encoded RTP payloads for the requested track or tracks.
5. If bidirectional streaming is enabled, the connected application can send `media`, `mark`, and `clear` frames back to Telnyx.
6. Telnyx sends `dtmf`, `mark`, `error`, and `stop` frames as applicable.

## Bidirectional Media
Bidirectional streaming is enabled through Call Control by setting `stream_bidirectional_mode` to `rtp` for RTP payloads, or by sending base64-encoded MP3 media frames for media-file playback. RTP media chunks sent back to Telnyx can contain 20 milliseconds to 30 seconds of audio. MP3 media frames are queued and played in submission order, with a one-message-per-second rate limit.

## Ordering
Media frame order is not guaranteed. Use `media.chunk`, `media.timestamp`, and `sequence_number` to order frames when required.




## AsyncAPI

````yaml openapi/asyncapi/media-streaming/media-streaming.yml media-streaming-websocket
id: media-streaming-websocket
title: Stream call media over WebSocket
description: >
  AsyncAPI specification for the Telnyx Media Streaming WebSocket connection.

  Media Streaming forks call media and delivers it to a customer-provided
  WebSocket URL configured through Call Control using `stream_url`. Telnyx opens
  the WebSocket connection, sends lifecycle and media frames, and can receive
  bidirectional media playback commands from the connected application.


  ## Connection Flow

  1. Start media streaming with a Call Control command and provide `stream_url`.

  2. Telnyx opens a WebSocket connection to the configured `stream_url`.

  3. Telnyx sends a `connected` frame, followed by a `start` frame that
  identifies the call and media format.

  4. Telnyx sends `media` frames with base64-encoded RTP payloads for the
  requested track or tracks.

  5. If bidirectional streaming is enabled, the connected application can send
  `media`, `mark`, and `clear` frames back to Telnyx.

  6. Telnyx sends `dtmf`, `mark`, `error`, and `stop` frames as applicable.


  ## Bidirectional Media

  Bidirectional streaming is enabled through Call Control by setting
  `stream_bidirectional_mode` to `rtp` for RTP payloads, or by sending
  base64-encoded MP3 media frames for media-file playback. RTP media chunks sent
  back to Telnyx can contain 20 milliseconds to 30 seconds of audio. MP3 media
  frames are queued and played in submission order, with a
  one-message-per-second rate limit.


  ## Ordering

  Media frame order is not guaranteed. Use `media.chunk`, `media.timestamp`, and
  `sequence_number` to order frames when required.
servers:
  - id: customer-media-streaming-websocket
    protocol: wss
    host: yourdomain.com
    bindings:
      - protocol: ws
        version: 0.1.0
        value: {}
        schemaProperties: []
    variables: []
address: /
parameters: []
bindings: []
operations:
  - &ref_6
    id: receiveTelnyxEvents
    title: Receive Media Streaming Events
    description: >-
      Telnyx sends connection, lifecycle, media, DTMF, mark callback, and error
      frames to the connected application.
    type: receive
    messages:
      - &ref_8
        id: telnyxConnected
        contentType: application/json
        payload:
          - name: Connected Frame
            description: >
              First frame sent by Telnyx after the WebSocket connection is
              established.

              When a streaming auth token is configured, Telnyx includes it in
              the `connected.x-telnyx-streaming-auth-token` field and sends it
              as the `x-telnyx-streaming-auth-token` WebSocket header.
            type: object
            properties:
              - name: event
                type: string
                description: connected
                required: true
              - name: version
                type: string
                description: Media Streaming protocol version.
                required: true
              - name: connected
                type: object
                description: Optional connection metadata.
                required: false
                properties:
                  - name: x-telnyx-streaming-auth-token
                    type: string
                    description: Optional streaming auth token configured for the stream.
                    required: false
        headers: []
        jsonPayloadSchema:
          type: object
          additionalProperties: false
          required:
            - event
            - version
          properties:
            event:
              type: string
              const: connected
              x-parser-schema-id: <anonymous-schema-1>
            version:
              type: string
              description: Media Streaming protocol version.
              example: 1.0.0
              x-parser-schema-id: <anonymous-schema-2>
            connected:
              type: object
              additionalProperties: false
              description: Optional connection metadata.
              properties:
                x-telnyx-streaming-auth-token:
                  type: string
                  description: Optional streaming auth token configured for the stream.
                  x-parser-schema-id: <anonymous-schema-4>
              x-parser-schema-id: <anonymous-schema-3>
          x-parser-schema-id: ConnectedFrame
        title: Connected Frame
        description: >
          First frame sent by Telnyx after the WebSocket connection is
          established.

          When a streaming auth token is configured, Telnyx includes it in the
          `connected.x-telnyx-streaming-auth-token` field and sends it as the
          `x-telnyx-streaming-auth-token` WebSocket header.
        example: |-
          {
            "event": "connected",
            "version": "1.0.0"
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: telnyxConnected
      - &ref_9
        id: telnyxStart
        contentType: application/json
        payload:
          - name: Start Frame
            description: >-
              Frame sent before media begins. Identifies the stream, call
              metadata, custom parameters, and media format.
            type: object
            properties:
              - name: event
                type: string
                description: start
                required: true
              - name: sequence_number
                type: string
                description: >-
                  Monotonic sequence number for frames sent by Telnyx on this
                  WebSocket connection.
                required: true
              - name: stream_id
                type: string
                description: Unique identifier for the media stream.
                required: true
              - name: start
                type: object
                required: true
                properties:
                  - name: user_id
                    type: string
                    description: Telnyx user identifier associated with the stream.
                    required: true
                  - name: call_control_id
                    type: string
                    description: Call Control ID for the call.
                    required: true
                  - name: call_session_id
                    type: string
                    description: Call session ID for the call.
                    required: false
                  - name: from
                    type: string
                    description: Caller number or SIP URI when available.
                    required: false
                  - name: to
                    type: string
                    description: Callee number or SIP URI when available.
                    required: false
                  - name: tags
                    type: array
                    description: Tags associated with the call.
                    required: false
                    properties:
                      - name: item
                        type: string
                        required: false
                  - name: client_state
                    type: string
                    description: Base64-encoded client state passed through Call Control.
                    required: false
                  - name: custom_parameters
                    type: object
                    description: >-
                      Custom parameters configured when starting the stream,
                      keyed by parameter name.
                    required: false
                  - name: media_format
                    type: object
                    required: true
                    properties:
                      - name: encoding
                        type: string
                        description: Codec used by the streamed media.
                        enumValues:
                          - PCMU
                          - PCMA
                          - G722
                          - OPUS
                          - AMR-WB
                          - L16
                        required: true
                      - name: sample_rate
                        type: integer
                        description: Media sample rate in Hz.
                        enumValues:
                          - 8000
                          - 16000
                        required: true
                      - name: channels
                        type: integer
                        description: Number of audio channels.
                        required: true
        headers: []
        jsonPayloadSchema:
          type: object
          additionalProperties: false
          required:
            - event
            - sequence_number
            - stream_id
            - start
          properties:
            event:
              type: string
              const: start
              x-parser-schema-id: <anonymous-schema-5>
            sequence_number: &ref_0
              type: string
              description: >-
                Monotonic sequence number for frames sent by Telnyx on this
                WebSocket connection.
              x-parser-schema-id: SequenceNumber
            stream_id: &ref_1
              type: string
              format: uuid
              description: Unique identifier for the media stream.
              x-parser-schema-id: StreamId
            start:
              type: object
              additionalProperties: false
              required:
                - user_id
                - call_control_id
                - media_format
              properties:
                user_id:
                  type: string
                  format: uuid
                  description: Telnyx user identifier associated with the stream.
                  x-parser-schema-id: <anonymous-schema-7>
                call_control_id:
                  type: string
                  description: Call Control ID for the call.
                  x-parser-schema-id: <anonymous-schema-8>
                call_session_id:
                  type: string
                  format: uuid
                  description: Call session ID for the call.
                  x-parser-schema-id: <anonymous-schema-9>
                from:
                  type: string
                  description: Caller number or SIP URI when available.
                  x-parser-schema-id: <anonymous-schema-10>
                to:
                  type: string
                  description: Callee number or SIP URI when available.
                  x-parser-schema-id: <anonymous-schema-11>
                tags:
                  type: array
                  description: Tags associated with the call.
                  items:
                    type: string
                    x-parser-schema-id: <anonymous-schema-13>
                  x-parser-schema-id: <anonymous-schema-12>
                client_state:
                  type: string
                  description: Base64-encoded client state passed through Call Control.
                  x-parser-schema-id: <anonymous-schema-14>
                custom_parameters:
                  type: object
                  description: >-
                    Custom parameters configured when starting the stream, keyed
                    by parameter name.
                  additionalProperties:
                    type: string
                    x-parser-schema-id: <anonymous-schema-16>
                  x-parser-schema-id: <anonymous-schema-15>
                media_format:
                  type: object
                  additionalProperties: false
                  required:
                    - encoding
                    - sample_rate
                    - channels
                  properties:
                    encoding:
                      type: string
                      description: Codec used by the streamed media.
                      enum:
                        - PCMU
                        - PCMA
                        - G722
                        - OPUS
                        - AMR-WB
                        - L16
                      x-parser-schema-id: <anonymous-schema-17>
                    sample_rate:
                      type: integer
                      description: Media sample rate in Hz.
                      enum:
                        - 8000
                        - 16000
                      x-parser-schema-id: <anonymous-schema-18>
                    channels:
                      type: integer
                      description: Number of audio channels.
                      const: 1
                      x-parser-schema-id: <anonymous-schema-19>
                  x-parser-schema-id: MediaFormat
              x-parser-schema-id: <anonymous-schema-6>
          x-parser-schema-id: StartFrame
        title: Start Frame
        description: >-
          Frame sent before media begins. Identifies the stream, call metadata,
          custom parameters, and media format.
        example: |-
          {
            "event": "start",
            "sequence_number": "1",
            "stream_id": "32DE0DEA-53CB-4B21-89A4-9E1819C043BC",
            "start": {
              "user_id": "3E6F995F-85F7-4705-9741-53B116D28237",
              "call_control_id": "v2:T02llQxIyaRkhfRKxgAP8nY511EhFLizdvdUKJiSw8d6A9BborherQ",
              "call_session_id": "ff55a038-6f5d-11ef-9692-02420aeffb1f",
              "from": "+13122010094",
              "to": "+13122123456",
              "tags": [
                "TAG1",
                "TAG2"
              ],
              "client_state": "aGF2ZSBhIG5pY2UgZGF5ID1d",
              "custom_parameters": {
                "customer_id": "customer_123"
              },
              "media_format": {
                "encoding": "PCMU",
                "sample_rate": 8000,
                "channels": 1
              }
            }
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: telnyxStart
      - &ref_10
        id: telnyxMedia
        contentType: application/json
        payload:
          - name: Telnyx Media Frame
            description: >-
              Telnyx-to-application media frame with a base64-encoded RTP
              payload without RTP headers.
            type: object
            properties:
              - name: event
                type: string
                description: media
                required: true
              - name: sequence_number
                type: string
                description: >-
                  Monotonic sequence number for frames sent by Telnyx on this
                  WebSocket connection.
                required: true
              - name: stream_id
                type: string
                description: Unique identifier for the media stream.
                required: true
              - name: media
                type: object
                required: true
                properties:
                  - name: track
                    type: string
                    description: Call leg track that produced the media frame.
                    enumValues:
                      - inbound
                      - outbound
                    required: true
                  - name: chunk
                    type: string
                    description: >-
                      Per-stream media chunk number. Use to reorder media frames
                      if needed.
                    required: true
                  - name: timestamp
                    type: string
                    description: RTP timestamp associated with this media frame.
                    required: true
                  - name: payload
                    type: string
                    description: Base64-encoded media payload.
                    required: true
        headers: []
        jsonPayloadSchema:
          type: object
          additionalProperties: false
          required:
            - event
            - sequence_number
            - stream_id
            - media
          properties:
            event:
              type: string
              const: media
              x-parser-schema-id: <anonymous-schema-20>
            sequence_number: *ref_0
            stream_id: *ref_1
            media:
              type: object
              additionalProperties: false
              required:
                - track
                - chunk
                - timestamp
                - payload
              properties:
                track:
                  type: string
                  description: Call leg track that produced the media frame.
                  enum:
                    - inbound
                    - outbound
                  x-parser-schema-id: <anonymous-schema-22>
                chunk:
                  type: string
                  description: >-
                    Per-stream media chunk number. Use to reorder media frames
                    if needed.
                  x-parser-schema-id: <anonymous-schema-23>
                timestamp:
                  type: string
                  description: RTP timestamp associated with this media frame.
                  x-parser-schema-id: <anonymous-schema-24>
                payload: &ref_3
                  type: string
                  format: byte
                  description: Base64-encoded media payload.
                  x-parser-schema-id: Base64Payload
              x-parser-schema-id: <anonymous-schema-21>
          x-parser-schema-id: TelnyxMediaFrame
        title: Telnyx Media Frame
        description: >-
          Telnyx-to-application media frame with a base64-encoded RTP payload
          without RTP headers.
        example: |-
          {
            "event": "media",
            "sequence_number": "4",
            "stream_id": "32DE0DEA-53CB-4B21-89A4-9E1819C043BC",
            "media": {
              "track": "inbound",
              "chunk": "2",
              "timestamp": "5",
              "payload": "no+JhoaJjpzSHxAKBgYJDhtEopGKh4aIjZm7JhILBwYIDRg1qZSLh4aIjJev"
            }
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: telnyxMedia
      - &ref_11
        id: telnyxStop
        contentType: application/json
        payload:
          - name: Stop Frame
            description: Frame sent when Telnyx stops media streaming for the call.
            type: object
            properties:
              - name: event
                type: string
                description: stop
                required: true
              - name: sequence_number
                type: string
                description: >-
                  Monotonic sequence number for frames sent by Telnyx on this
                  WebSocket connection.
                required: true
              - name: stream_id
                type: string
                description: Unique identifier for the media stream.
                required: true
              - name: stop
                type: object
                required: true
                properties:
                  - name: user_id
                    type: string
                    description: Telnyx user identifier associated with the stream.
                    required: true
                  - name: call_control_id
                    type: string
                    description: Call Control ID for the call.
                    required: true
        headers: []
        jsonPayloadSchema:
          type: object
          additionalProperties: false
          required:
            - event
            - sequence_number
            - stream_id
            - stop
          properties:
            event:
              type: string
              const: stop
              x-parser-schema-id: <anonymous-schema-25>
            sequence_number: *ref_0
            stream_id: *ref_1
            stop:
              type: object
              additionalProperties: false
              required:
                - user_id
                - call_control_id
              properties:
                user_id:
                  type: string
                  format: uuid
                  description: Telnyx user identifier associated with the stream.
                  x-parser-schema-id: <anonymous-schema-27>
                call_control_id:
                  type: string
                  description: Call Control ID for the call.
                  x-parser-schema-id: <anonymous-schema-28>
              x-parser-schema-id: <anonymous-schema-26>
          x-parser-schema-id: StopFrame
        title: Stop Frame
        description: Frame sent when Telnyx stops media streaming for the call.
        example: |-
          {
            "event": "stop",
            "sequence_number": "5",
            "stream_id": "32DE0DEA-53CB-4B21-89A4-9E1819C043BC",
            "stop": {
              "user_id": "3E6F995F-85F7-4705-9741-53B116D28237",
              "call_control_id": "v2:T02llQxIyaRkhfRKxgAP8nY511EhFLizdvdUKJiSw8d6A9BborherQ"
            }
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: telnyxStop
      - &ref_12
        id: telnyxMark
        contentType: application/json
        payload:
          - allOf: &ref_2
              - type: object
                additionalProperties: false
                required:
                  - event
                  - sequence_number
                  - stream_id
                  - mark
                properties:
                  event:
                    type: string
                    const: mark
                    x-parser-schema-id: <anonymous-schema-29>
                  sequence_number: *ref_0
                  stream_id: *ref_1
                  mark: &ref_4
                    type: object
                    additionalProperties: false
                    required:
                      - name
                    properties:
                      name:
                        type: string
                        description: Customer-defined mark name.
                        x-parser-schema-id: <anonymous-schema-30>
                    x-parser-schema-id: Mark
                x-parser-schema-id: SequencedMarkFrame
            x-parser-schema-id: MarkCallbackFrame
            name: Mark Callback Frame
            description: >
              Telnyx sends a mark callback when the media immediately preceding
              a submitted mark finishes playing.

              If no audio is playing or queued, the mark is returned
              immediately. A clear frame also returns queued marks.
        headers: []
        jsonPayloadSchema:
          allOf: *ref_2
          x-parser-schema-id: MarkCallbackFrame
        title: Mark Callback Frame
        description: >
          Telnyx sends a mark callback when the media immediately preceding a
          submitted mark finishes playing.

          If no audio is playing or queued, the mark is returned immediately. A
          clear frame also returns queued marks.
        example: |-
          {
            "event": "mark",
            "sequence_number": "5",
            "stream_id": "32DE0DEA-53CB-4B21-89A4-9E1819C043BC",
            "mark": {
              "name": "some_mark_name"
            }
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: telnyxMark
      - &ref_13
        id: telnyxDtmf
        contentType: application/json
        payload:
          - name: DTMF Frame
            description: Frame sent when Telnyx detects DTMF on the call.
            type: object
            properties:
              - name: event
                type: string
                description: dtmf
                required: true
              - name: sequence_number
                type: string
                description: >-
                  Monotonic sequence number for frames sent by Telnyx on this
                  WebSocket connection.
                required: true
              - name: stream_id
                type: string
                description: Unique identifier for the media stream.
                required: true
              - name: occurred_at
                type: string
                description: >-
                  Timestamp captured by the telephony engine. Use this to order
                  DTMF events if they arrive out of order.
                required: false
              - name: dtmf
                type: object
                required: true
                properties:
                  - name: digit
                    type: string
                    description: DTMF digit detected on the call.
                    enumValues:
                      - '0'
                      - '1'
                      - '2'
                      - '3'
                      - '4'
                      - '5'
                      - '6'
                      - '7'
                      - '8'
                      - '9'
                      - '*'
                      - '#'
                      - A
                      - B
                      - C
                      - D
                    required: true
        headers: []
        jsonPayloadSchema:
          type: object
          additionalProperties: false
          required:
            - event
            - sequence_number
            - stream_id
            - dtmf
          properties:
            event:
              type: string
              const: dtmf
              x-parser-schema-id: <anonymous-schema-31>
            sequence_number: *ref_0
            stream_id: *ref_1
            occurred_at:
              type: string
              format: date-time
              description: >-
                Timestamp captured by the telephony engine. Use this to order
                DTMF events if they arrive out of order.
              x-parser-schema-id: <anonymous-schema-32>
            dtmf:
              type: object
              additionalProperties: false
              required:
                - digit
              properties:
                digit:
                  type: string
                  description: DTMF digit detected on the call.
                  enum:
                    - '0'
                    - '1'
                    - '2'
                    - '3'
                    - '4'
                    - '5'
                    - '6'
                    - '7'
                    - '8'
                    - '9'
                    - '*'
                    - '#'
                    - A
                    - B
                    - C
                    - D
                  x-parser-schema-id: <anonymous-schema-34>
              x-parser-schema-id: <anonymous-schema-33>
          x-parser-schema-id: DtmfFrame
        title: DTMF Frame
        description: Frame sent when Telnyx detects DTMF on the call.
        example: |-
          {
            "event": "dtmf",
            "stream_id": "32DE0DEA-53CB-4B21-89A4-9E1819C043BC",
            "occurred_at": "2025-06-05T08:54:19.698408Z",
            "sequence_number": "5",
            "dtmf": {
              "digit": "1"
            }
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: telnyxDtmf
      - &ref_14
        id: telnyxError
        contentType: application/json
        payload:
          - name: Error Frame
            description: Frame sent when an error occurs during media streaming.
            type: object
            properties:
              - name: event
                type: string
                description: error
                required: true
              - name: stream_id
                type: string
                description: Unique identifier for the media stream.
                required: true
              - name: payload
                type: object
                required: true
                properties:
                  - name: code
                    type: integer
                    description: Media Streaming error code.
                    enumValues:
                      - 100002
                      - 100003
                      - 100004
                      - 100005
                    required: true
                  - name: title
                    type: string
                    description: Media Streaming error title.
                    enumValues:
                      - unknown_error
                      - malformed_frame
                      - invalid_media
                      - rate_limit_reached
                    required: true
                  - name: detail
                    type: string
                    description: Human-readable error detail.
                    required: true
        headers: []
        jsonPayloadSchema:
          type: object
          additionalProperties: false
          required:
            - event
            - stream_id
            - payload
          properties:
            event:
              type: string
              const: error
              x-parser-schema-id: <anonymous-schema-35>
            stream_id: *ref_1
            payload:
              type: object
              additionalProperties: false
              required:
                - code
                - title
                - detail
              properties:
                code:
                  type: integer
                  description: Media Streaming error code.
                  enum:
                    - 100002
                    - 100003
                    - 100004
                    - 100005
                  x-parser-schema-id: <anonymous-schema-37>
                title:
                  type: string
                  description: Media Streaming error title.
                  enum:
                    - unknown_error
                    - malformed_frame
                    - invalid_media
                    - rate_limit_reached
                  x-parser-schema-id: <anonymous-schema-38>
                detail:
                  type: string
                  description: Human-readable error detail.
                  x-parser-schema-id: <anonymous-schema-39>
              x-parser-schema-id: <anonymous-schema-36>
          x-parser-schema-id: ErrorFrame
        title: Error Frame
        description: Frame sent when an error occurs during media streaming.
        example: |-
          {
            "event": "error",
            "stream_id": "32DE0DEA-53CB-4B21-89A4-9E1819C043BC",
            "payload": {
              "code": 100004,
              "title": "invalid_media",
              "detail": "Media provided was not base64 encoded"
            }
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: telnyxError
    bindings: []
    extensions: &ref_5
      - id: x-parser-unique-object-id
        value: media-streaming-websocket
  - &ref_7
    id: sendBidirectionalCommands
    title: Send Bidirectional Media Commands
    description: >-
      Connected applications send media, mark, and clear frames to play audio
      into the call or manage queued playback.
    type: send
    messages:
      - &ref_15
        id: clientMedia
        contentType: application/json
        payload:
          - name: Client Media Frame
            description: >
              Application-to-Telnyx media frame.

              In RTP bidirectional mode, `media.payload` is a base64-encoded RTP
              payload. Supported RTP codecs are PCMU, PCMA, G722, OPUS, AMR-WB,
              and L16. For media-file playback, `media.payload` is a
              base64-encoded MP3 file.
            type: object
            properties:
              - name: event
                type: string
                description: media
                required: true
              - name: media
                type: object
                required: true
                properties:
                  - name: payload
                    type: string
                    description: Base64-encoded media payload.
                    required: true
        headers: []
        jsonPayloadSchema:
          type: object
          additionalProperties: false
          required:
            - event
            - media
          properties:
            event:
              type: string
              const: media
              x-parser-schema-id: <anonymous-schema-40>
            media:
              type: object
              additionalProperties: false
              required:
                - payload
              properties:
                payload: *ref_3
              x-parser-schema-id: <anonymous-schema-41>
          x-parser-schema-id: ClientMediaFrame
        title: Client Media Frame
        description: >
          Application-to-Telnyx media frame.

          In RTP bidirectional mode, `media.payload` is a base64-encoded RTP
          payload. Supported RTP codecs are PCMU, PCMA, G722, OPUS, AMR-WB, and
          L16. For media-file playback, `media.payload` is a base64-encoded MP3
          file.
        example: |-
          {
            "event": "media",
            "media": {
              "payload": "eW91ciBiYXNlNjQgZW5jb2RlZCBhdWRpbyBwYXlsb2Fk"
            }
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: clientMedia
      - &ref_16
        id: clientMark
        contentType: application/json
        payload:
          - name: Mark Frame
            description: >
              Application-to-Telnyx mark frame used to track media completion.

              Send a mark after a media frame. Telnyx sends the same mark back
              when the immediately preceding media finishes playing, or
              immediately if no audio is queued.
            type: object
            properties:
              - name: event
                type: string
                description: mark
                required: true
              - name: mark
                type: object
                required: true
                properties:
                  - name: name
                    type: string
                    description: Customer-defined mark name.
                    required: true
        headers: []
        jsonPayloadSchema:
          type: object
          additionalProperties: false
          required:
            - event
            - mark
          properties:
            event:
              type: string
              const: mark
              x-parser-schema-id: <anonymous-schema-43>
            mark: *ref_4
          x-parser-schema-id: MarkFrame
        title: Mark Frame
        description: >
          Application-to-Telnyx mark frame used to track media completion.

          Send a mark after a media frame. Telnyx sends the same mark back when
          the immediately preceding media finishes playing, or immediately if no
          audio is queued.
        example: |-
          {
            "event": "mark",
            "mark": {
              "name": "some_mark_name"
            }
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: clientMark
      - &ref_17
        id: clientClear
        contentType: application/json
        payload:
          - name: Clear Frame
            description: >-
              Stops the current media playback and clears queued media. Queued
              marks are sent back by Telnyx.
            type: object
            properties:
              - name: event
                type: string
                description: clear
                required: true
        headers: []
        jsonPayloadSchema:
          type: object
          additionalProperties: false
          required:
            - event
          properties:
            event:
              type: string
              const: clear
              x-parser-schema-id: <anonymous-schema-42>
          x-parser-schema-id: ClearFrame
        title: Clear Frame
        description: >-
          Stops the current media playback and clears queued media. Queued marks
          are sent back by Telnyx.
        example: |-
          {
            "event": "clear"
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: clientClear
    bindings: []
    extensions: *ref_5
sendOperations:
  - *ref_6
receiveOperations:
  - *ref_7
sendMessages:
  - *ref_8
  - *ref_9
  - *ref_10
  - *ref_11
  - *ref_12
  - *ref_13
  - *ref_14
receiveMessages:
  - *ref_15
  - *ref_16
  - *ref_17
extensions:
  - id: x-parser-unique-object-id
    value: media-streaming-websocket
securitySchemes: []

````