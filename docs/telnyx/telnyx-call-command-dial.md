> ## Documentation Index
> Fetch the complete documentation index at: https://developers.telnyx.com/llms.txt
> Use this file to discover all available pages before exploring further.

# Dial

> Dial a number or SIP URI from a given connection. A successful response will include a `call_leg_id` which can be used to correlate the command with subsequent webhooks.

**Expected Webhooks:**

- `call.initiated`
- `call.answered` or `call.hangup`
- `call.hold` and `call.unhold` if the call is held/unheld
- `call.machine.detection.ended` if `answering_machine_detection` was requested
- `call.machine.greeting.ended` if `answering_machine_detection` was requested to detect the end of machine greeting
- `call.machine.premium.detection.ended` if `answering_machine_detection=premium` was requested
- `call.machine.premium.greeting.ended` if `answering_machine_detection=premium` was requested and a beep was detected
- `call.deepfake_detection.result` if `deepfake_detection` was enabled
- `call.deepfake_detection.error` if `deepfake_detection` was enabled and an error occurred
- `streaming.started`, `streaming.stopped` or `streaming.failed` if `stream_url` was set

When the `record` parameter is set to `record-from-answer`, the response will include a `recording_id` field.




## OpenAPI

````yaml /openapi/source/external/call-control/call-control.json post /calls
openapi: 3.1.0
info:
  version: 2.0.0
  title: Telnyx API
  x-latency-category: interactive
  x-endpoint-cost: light
  description: SIP trunking, SMS, MMS, Call Control and Telephony Data Services.
  contact:
    email: support@telnyx.com
  x-responsible-team: squad-telephony-apps
servers:
  - url: https://api.telnyx.com/v2
    description: Version 2.0.0 of the Telnyx API
security:
  - bearerAuth: []
tags:
  - name: Call Commands
    description: Call Control command operations
  - name: Conference Commands
    description: Conference command operations
  - name: Debugging
    description: Call Control debugging
  - name: Call Information
    description: Call information
  - name: Call Control Applications
    description: Call Control applications operations
  - name: Queue Commands
    description: Queue commands operations
  - name: Text to Speech Commands
    description: Text to Speech commands operations
  - name: Callbacks
    description: Callbacks
paths:
  /calls:
    post:
      tags:
        - Call Commands
      summary: Dial
      description: >
        Dial a number or SIP URI from a given connection. A successful response
        will include a `call_leg_id` which can be used to correlate the command
        with subsequent webhooks.


        **Expected Webhooks:**


        - `call.initiated`

        - `call.answered` or `call.hangup`

        - `call.hold` and `call.unhold` if the call is held/unheld

        - `call.machine.detection.ended` if `answering_machine_detection` was
        requested

        - `call.machine.greeting.ended` if `answering_machine_detection` was
        requested to detect the end of machine greeting

        - `call.machine.premium.detection.ended` if
        `answering_machine_detection=premium` was requested

        - `call.machine.premium.greeting.ended` if
        `answering_machine_detection=premium` was requested and a beep was
        detected

        - `call.deepfake_detection.result` if `deepfake_detection` was enabled

        - `call.deepfake_detection.error` if `deepfake_detection` was enabled
        and an error occurred

        - `streaming.started`, `streaming.stopped` or `streaming.failed` if
        `stream_url` was set


        When the `record` parameter is set to `record-from-answer`, the response
        will include a `recording_id` field.
      operationId: DialCall
      requestBody:
        description: Call request
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/CallRequest'
      responses:
        '200':
          description: >-
            Successful response with details about a call status that includes
            recording_id.
          content:
            application/json:
              schema:
                type: object
                title: Retrieve Call Status Response With Recording ID
                properties:
                  data:
                    $ref: '#/components/schemas/CallWithRecordingId'
        '400':
          $ref: '#/components/responses/BadRequestResponse'
        '422':
          $ref: '#/components/responses/UnprocessableEntityResponse'
        '500':
          $ref: '#/components/responses/InternalServerErrorResponse'
        '503':
          $ref: '#/components/responses/ServiceUnavailableResponse'
        default:
          $ref: '#/components/responses/GenericErrorResponse'
      x-codeSamples:
        - lang: JavaScript
          source: |-
            import Telnyx from 'telnyx';

            const client = new Telnyx({
              apiKey: process.env['TELNYX_API_KEY'], // This is the default and can be omitted
            });

            const response = await client.calls.dial({
              connection_id: '7267xxxxxxxxxxxxxx',
              from: '+18005550101',
              to: '+18005550100 or sip:username@sip.telnyx.com;secure=srtp',
            });

            console.log(response.data);
        - lang: Python
          source: |
            import os
            from telnyx import Telnyx

            client = Telnyx(
                api_key=os.environ.get("TELNYX_API_KEY"),  # This is the default and can be omitted
            )
            response = client.calls.dial(
                connection_id="7267xxxxxxxxxxxxxx",
                from_="+18005550101",
                to="+18005550100 or sip:username@sip.telnyx.com;secure=srtp",
            )
            print(response.data)
        - lang: Go
          source: "package main\n\nimport (\n\t\"context\"\n\t\"fmt\"\n\n\t\"github.com/team-telnyx/telnyx-go\"\n\t\"github.com/team-telnyx/telnyx-go/option\"\n)\n\nfunc main() {\n\tclient := telnyx.NewClient(\n\t\toption.WithAPIKey(\"My API Key\"),\n\t)\n\tresponse, err := client.Calls.Dial(context.TODO(), telnyx.CallDialParams{\n\t\tConnectionID: \"7267xxxxxxxxxxxxxx\",\n\t\tFrom:         \"+18005550101\",\n\t\tTo: telnyx.CallDialParamsToUnion{\n\t\t\tOfString: telnyx.String(\"+18005550100 or sip:username@sip.telnyx.com;secure=srtp\"),\n\t\t},\n\t})\n\tif err != nil {\n\t\tpanic(err.Error())\n\t}\n\tfmt.Printf(\"%+v\\n\", response.Data)\n}\n"
        - lang: Java
          source: |-
            package com.telnyx.sdk.example;

            import com.telnyx.sdk.client.TelnyxClient;
            import com.telnyx.sdk.client.okhttp.TelnyxOkHttpClient;
            import com.telnyx.sdk.models.calls.CallDialParams;
            import com.telnyx.sdk.models.calls.CallDialResponse;

            public final class Main {
                private Main() {}

                public static void main(String[] args) {
                    TelnyxClient client = TelnyxOkHttpClient.fromEnv();

                    CallDialParams params = CallDialParams.builder()
                        .connectionId("7267xxxxxxxxxxxxxx")
                        .from("+18005550101")
                        .to("+18005550100 or sip:username@sip.telnyx.com;secure=srtp")
                        .build();
                    CallDialResponse response = client.calls().dial(params);
                }
            }
        - lang: Ruby
          source: |-
            require "telnyx"

            telnyx = Telnyx::Client.new(api_key: "My API Key")

            response = telnyx.calls.dial(
              connection_id: "7267xxxxxxxxxxxxxx",
              from: "+18005550101",
              to: "+18005550100 or sip:username@sip.telnyx.com;secure=srtp"
            )

            puts(response)
        - lang: PHP
          source: >-
            <?php


            require_once dirname(__DIR__) . '/vendor/autoload.php';


            use Telnyx\Client;

            use Telnyx\Calls\StreamBidirectionalCodec;

            use Telnyx\Calls\StreamBidirectionalMode;

            use Telnyx\Calls\StreamBidirectionalSamplingRate;

            use Telnyx\Calls\StreamBidirectionalTargetLegs;

            use Telnyx\Calls\StreamCodec;

            use Telnyx\Calls\Actions\GoogleTranscriptionLanguage;

            use Telnyx\Core\Exceptions\APIException;


            $client = new Client(apiKey: getenv('TELNYX_API_KEY') ?: 'My API
            Key');


            try {
              $response = $client->calls->dial(
                connectionID: '7267xxxxxxxxxxxxxx',
                from: '+18005550101',
                to: '+18005550100 or sip:username@sip.telnyx.com;secure=srtp',
                answeringMachineDetection: 'detect',
                answeringMachineDetectionConfig: [
                  'afterGreetingSilenceMillis' => 1000,
                  'betweenWordsSilenceMillis' => 1000,
                  'greetingDurationMillis' => 1000,
                  'greetingSilenceDurationMillis' => 2000,
                  'greetingTotalAnalysisTimeMillis' => 50000,
                  'initialSilenceMillis' => 1000,
                  'maximumNumberOfWords' => 1000,
                  'maximumWordLengthMillis' => 2000,
                  'silenceThreshold' => 512,
                  'totalAnalysisTimeMillis' => 5000,
                ],
                assistant: [
                  'id' => 'id',
                  'dynamicVariables' => [
                    'customer_name' => 'John', 'account_id' => 'ACC-12345'
                  ],
                  'externalLlm' => [
                    'authenticationMethod' => 'token',
                    'baseURL' => 'base_url',
                    'certificateRef' => 'certificate_ref',
                    'forwardMetadata' => true,
                    'llmAPIKeyRef' => 'llm_api_key_ref',
                    'model' => 'model',
                    'tokenRetrievalURL' => 'token_retrieval_url',
                  ],
                  'fallbackConfig' => [
                    'externalLlm' => [
                      'authenticationMethod' => 'token',
                      'baseURL' => 'base_url',
                      'certificateRef' => 'certificate_ref',
                      'forwardMetadata' => true,
                      'llmAPIKeyRef' => 'llm_api_key_ref',
                      'model' => 'model',
                      'tokenRetrievalURL' => 'token_retrieval_url',
                    ],
                    'llmAPIKeyRef' => 'llm_api_key_ref',
                    'model' => 'model',
                  ],
                  'greeting' => 'greeting',
                  'instructions' => 'You are a friendly voice assistant.',
                  'llmAPIKeyRef' => 'my_llm_api_key',
                  'mcpServers' => [['foo' => 'bar']],
                  'model' => 'gpt-4o',
                  'name' => 'name',
                  'observabilitySettings' => ['foo' => 'bar'],
                  'openaiAPIKeyRef' => 'my_openai_api_key',
                  'tools' => [
                    [
                      'bookAppointment' => [
                        'apiKeyRef' => 'my_calcom_api_key',
                        'eventTypeID' => 0,
                        'attendeeName' => 'attendee_name',
                        'attendeeTimezone' => 'attendee_timezone',
                      ],
                      'type' => 'book_appointment',
                    ],
                  ],
                ],
                audioURL: 'http://www.example.com/sounds/greeting.wav',
                billingGroupID: 'f5586561-8ff0-4291-a0ac-84fe544797bd',
                bridgeIntent: true,
                bridgeOnAnswer: true,
                clientState: 'aGF2ZSBhIG5pY2UgZGF5ID1d',
                commandID: '891510ac-f3e4-11e8-af5b-de00688a4901',
                conferenceConfig: [
                  'id' => '0ccc7b54-4df3-4bca-a65a-3da1ecc777f0',
                  'beepEnabled' => 'on_exit',
                  'conferenceName' => 'telnyx-conference',
                  'earlyMedia' => false,
                  'endConferenceOnExit' => true,
                  'hold' => true,
                  'holdAudioURL' => 'http://example.com/message.wav',
                  'holdMediaName' => 'my_media_uploaded_to_media_storage_api',
                  'mute' => true,
                  'softEndConferenceOnExit' => true,
                  'startConferenceOnCreate' => false,
                  'startConferenceOnEnter' => true,
                  'supervisorRole' => 'whisper',
                  'whisperCallControlIDs' => [
                    'v2:Sg1xxxQ_U3ixxxyXT_VDNI3xxxazZdg6Vxxxs4-GNYxxxVaJPOhFMRQ',
                    'v2:qqpb0mmvd-ovhhBr0BUQQn0fld5jIboaaX3-De0DkqXHzbf8d75xkw',
                  ],
                ],
                conversationRelayConfig: [
                  'url' => 'wss://example.com/conversation-relay',
                  'customParameters' => ['customer_id' => 'bar'],
                  'dtmfDetection' => true,
                  'greeting' => 'Hi! Ask me anything!',
                  'interruptible' => 'speech',
                  'interruptibleGreeting' => 'dtmf',
                  'interruptionSettings' => [
                    'enable' => true,
                    'interruptible' => 'speech',
                    'interruptibleGreeting' => 'speech',
                    'welcomeGreetingInterruptible' => 'speech',
                  ],
                  'language' => 'en-US',
                  'languages' => [
                    [
                      'language' => 'en-US',
                      'speechModel' => 'nova-3',
                      'transcriptionEngine' => 'Deepgram',
                      'transcriptionEngineConfig' => ['transcription_model' => 'bar'],
                      'transcriptionProvider' => 'Deepgram',
                      'ttsProvider' => 'telnyx',
                      'voice' => 'Telnyx.Ultra.alloy',
                      'voiceSettings' => [
                        'type' => 'elevenlabs', 'apiKeyRef' => 'my_elevenlabs_api_key'
                      ],
                    ],
                  ],
                  'provider' => 'elevenlabs',
                  'structuredProvider' => ['voice_id' => 'bar', 'model_id' => 'bar'],
                  'transcriptionEngine' => 'Google',
                  'transcriptionEngineConfig' => [
                    'transcription_model' => 'bar',
                    'interim_results' => 'bar',
                    'keywords_boosting' => 'bar',
                  ],
                  'ttsProvider' => 'telnyx',
                  'voice' => 'Telnyx.KokoroTTS.af',
                  'voiceSettings' => ['type' => 'telnyx', 'voiceSpeed' => 1],
                ],
                customHeaders: [
                  ['name' => 'head_1', 'value' => 'val_1'],
                  ['name' => 'head_2', 'value' => 'val_2'],
                ],
                deepfakeDetection: ['enabled' => true, 'rtpTimeout' => 30, 'timeout' => 15],
                dialogflowConfig: [
                  'analyzeSentiment' => false, 'partialAutomatedAgentReply' => false
                ],
                enableDialogflow: false,
                fromDisplayName: 'Company Name',
                linkTo: 'ilditnZK_eVysupV21KzmzN_sM29ygfauQojpm4BgFtfX5hXAcjotg==',
                mediaEncryption: 'SRTP',
                mediaName: 'my_media_uploaded_to_media_storage_api',
                parkAfterUnbridge: 'self',
                preferredCodecs: 'G722,PCMU,PCMA,G729,OPUS,VP8,H264',
                preventDoubleBridge: true,
                privacy: 'id',
                record: 'record-from-answer',
                recordChannels: 'single',
                recordCustomFileName: 'my_recording_file_name',
                recordFormat: 'wav',
                recordMaxLength: 1000,
                recordTimeoutSecs: 100,
                recordTrack: 'outbound',
                recordTrim: 'trim-silence',
                sendDigitsOnAnswer: 'wwww200',
                sendSilenceWhenIdle: true,
                sipAuthPassword: 'password',
                sipAuthUsername: 'username',
                sipHeaders: [['name' => 'User-to-User', 'value' => '12345']],
                sipRegion: 'Canada',
                sipTransportProtocol: 'TLS',
                soundModifications: [
                  'octaves' => 0.1, 'pitch' => 0.8, 'semitone' => -2, 'track' => 'both'
                ],
                streamAuthToken: 'your-auth-token',
                streamBidirectionalCodec: StreamBidirectionalCodec::G722,
                streamBidirectionalMode: StreamBidirectionalMode::RTP,
                streamBidirectionalSamplingRate: StreamBidirectionalSamplingRate::RATE_16000,
                streamBidirectionalTargetLegs: StreamBidirectionalTargetLegs::BOTH,
                streamCodec: StreamCodec::PCMA,
                streamEstablishBeforeCallOriginate: true,
                streamTrack: 'both_tracks',
                streamURL: 'wss://www.example.com/websocket',
                superviseCallControlID: 'v3:MdI91X4lWFEs7IgbBEOT9M4AigoY08M0WWZFISt1Yw2axZ_IiE4pqg',
                supervisorRole: 'barge',
                timeLimitSecs: 60,
                timeoutSecs: 60,
                transcription: true,
                transcriptionConfig: [
                  'clientState' => 'aGF2ZSBhIG5pY2UgZGF5ID1d',
                  'commandID' => '891510ac-f3e4-11e8-af5b-de00688a4901',
                  'transcriptionEngine' => 'Google',
                  'transcriptionEngineConfig' => [
                    'enableSpeakerDiarization' => true,
                    'hints' => ['string'],
                    'interimResults' => true,
                    'language' => GoogleTranscriptionLanguage::EN,
                    'maxSpeakerCount' => 4,
                    'minSpeakerCount' => 4,
                    'model' => 'latest_long',
                    'profanityFilter' => true,
                    'speechContext' => [['boost' => 1, 'phrases' => ['string']]],
                    'transcriptionEngine' => 'Google',
                    'useEnhanced' => true,
                  ],
                  'transcriptionTracks' => 'both',
                ],
                webhookRetriesPolicies: [
                  'call.hangup' => ['retriesMs' => [1000, 2000, 5000]]
                ],
                webhookURL: 'https://www.example.com/server-b/',
                webhookURLMethod: 'POST',
                webhookURLs: [
                  'call.hangup' => 'https://www.example.com/webhooks/hangup',
                  'call.bridge' => 'https://www.example.com/webhooks/bridge',
                ],
                webhookURLsMethod: 'POST',
              );

              var_dump($response);
            } catch (APIException $e) {
              echo $e->getMessage();
            }
        - lang: CLI
          source: |-
            telnyx calls dial \
              --api-key 'My API Key' \
              --connection-id 7267xxxxxxxxxxxxxx \
              --from +18005550101 \
              --to '+18005550100 or sip:username@sip.telnyx.com;secure=srtp'
components:
  schemas:
    CallRequest:
      type: object
      title: Dial Request
      required:
        - connection_id
        - to
        - from
      example:
        to: +18005550100 or sip:username@sip.telnyx.com;secure=srtp
        from: '+18005550101'
        from_display_name: Company Name
        connection_id: 7267xxxxxxxxxxxxxx
        conference_config:
          conference_name: telnyx-conference
          start_conference_on_enter: true
        audio_url: http://www.example.com/sounds/greeting.wav
        send_digits_on_answer: wwww200
        timeout_secs: 60
        time_limit_secs: 60
        webhook_url: https://www.example.com/server-b/
        webhook_url_method: POST
        webhook_urls:
          call.hangup:
            - https://www.example.com/webhooks/hangup
          call.bridge:
            - https://www.example.com/webhooks/bridge
        webhook_urls_method: POST
        webhook_retries_policies:
          call.hangup:
            retries_ms:
              - 1000
              - 2000
              - 5000
        answering_machine_detection: detect
        answering_machine_detection_config:
          total_analysis_time_millis: 5000
          after_greeting_silence_millis: 1000
          between_words_silence_millis: 1000
          greeting_duration_millis: 1000
          initial_silence_millis: 1000
          maximum_number_of_words: 1000
          maximum_word_length_millis: 2000
          silence_threshold: 512
          greeting_total_analysis_time_millis: 50000
          greeting_silence_duration_millis: 2000
        deepfake_detection:
          enabled: true
          timeout: 15
          rtp_timeout: 30
        custom_headers:
          - name: head_1
            value: val_1
          - name: head_2
            value: val_2
        client_state: aGF2ZSBhIG5pY2UgZGF5ID1d
        command_id: 891510ac-f3e4-11e8-af5b-de00688a4901
        link_to: ilditnZK_eVysupV21KzmzN_sM29ygfauQojpm4BgFtfX5hXAcjotg==
        bridge_intent: true
        bridge_on_answer: true
        media_encryption: SRTP
        sip_auth_username: username
        sip_auth_password: password
        sip_headers:
          - name: User-to-User
            value: '12345'
        sip_transport_protocol: TLS
        stream_url: wss://www.example.com/websocket
        stream_track: both_tracks
        send_silence_when_idle: true
        enable_dialogflow: false
        dialogflow_config:
          analyze_sentiment: false
          partial_automated_agent_reply: false
        conversation_relay_config:
          url: wss://example.com/conversation-relay
          dtmf_detection: true
          greeting: Hi! Ask me anything!
          voice: Telnyx.KokoroTTS.af
          tts_provider: telnyx
          language: en-US
          interruptible: speech
          interruptible_greeting: dtmf
          custom_parameters:
            customer_id: '12345'
      properties:
        assistant:
          $ref: '#/components/schemas/CallAssistantRequest'
        conversation_relay_config:
          $ref: '#/components/schemas/ConversationRelayEmbeddedConfig'
        to:
          description: >-
            The DID or SIP URI to dial out to. Multiple DID or SIP URIs can be
            provided using an array of strings. For SIP URI destinations, append
            `;secure=true` or `;secure=srtp` to enable SRTP media encryption for
            that endpoint, or `;secure=dtls` to enable DTLS media encryption for
            that endpoint. If `media_encryption` is set to `SRTP` or `DTLS`, it
            takes precedence over any per-endpoint `secure` URI parameter. For a
            single string destination, you may append a comma followed by DTMF
            digits (e.g. `+18004247767,200`) to play those digits as DTMF once
            the called party answers — equivalent to setting
            `send_digits_on_answer` separately. If both are present, the
            explicit `send_digits_on_answer` parameter takes precedence. This
            shorthand is not supported when `to` is an array.
          oneOf:
            - type: string
              example: +18005550100 or sip:username@sip.telnyx.com;secure=srtp
            - type: array
              items:
                type: string
              example:
                - '+18005550100'
                - sip:username@sip.telnyx.com;secure=srtp
        from:
          description: >-
            The `from` number to be used as the caller id presented to the
            destination (`to` number). The number should be in +E164 format.
          type: string
          example: '+18005550101'
        from_display_name:
          description: >-
            The `from_display_name` string to be used as the caller id name (SIP
            From Display Name) presented to the destination (`to` number). The
            string should have a maximum of 128 characters, containing only
            letters, numbers, spaces, and -_~!.+ special characters. If ommited,
            the display name will be the same as the number in the `from` field.
          type: string
          example: Company Name
        privacy:
          type: string
          description: >-
            Indicates the privacy level to be used for the call. When set to
            `id`, caller ID information (name and number) will be hidden from
            the called party. When set to `none` or omitted, caller ID will be
            shown normally.
          enum:
            - id
            - none
          example: id
        connection_id:
          type: string
          description: >-
            The ID of the Call Control App (formerly ID of the connection) to be
            used when dialing the destination.
        audio_url:
          type: string
          example: http://example.com/message.wav
          description: >-
            The URL of a file to be played back to the callee when the call is
            answered. The URL can point to either a WAV or MP3 file. media_name
            and audio_url cannot be used together in one request.
        send_digits_on_answer:
          type: string
          example: wwww200
          description: >-
            DTMF digits to send automatically after the called party answers.
            Useful for reaching an extension behind an IVR (e.g. `"200"` to dial
            extension 200 once the called party picks up). Allowed characters:
            `0-9`, `A-D`, `w` (0.5s pause), `W` (1s pause), `*`, `#`. Maximum 64
            characters. When omitted, no automatic DTMF is sent. May also be
            supplied inline by appending `,<digits>` to `to` (e.g.
            `to=+18004247767,200`); if both forms are present, this explicit
            field takes precedence.
        media_name:
          type: string
          example: my_media_uploaded_to_media_storage_api
          description: >-
            The media_name of a file to be played back to the callee when the
            call is answered. The media_name must point to a file previously
            uploaded to api.telnyx.com/v2/media by the same user/organization.
            The file must either be a WAV or MP3 file.
        preferred_codecs:
          type: string
          description: >-
            The list of comma-separated codecs in a preferred order for the
            forked media to be received.
          example: G722,PCMU,PCMA,G729,OPUS,VP8,H264
        timeout_secs:
          description: >-
            The number of seconds that Telnyx will wait for the call to be
            answered by the destination to which it is being called. If the
            timeout is reached before an answer is received, the call will
            hangup and a `call.hangup` webhook with a `hangup_cause` of
            `timeout` will be sent. Minimum value is 5 seconds. Maximum value is
            600 seconds.
          default: 30
          type: integer
          example: 60
          format: int32
        retry_on_timeout:
          description: >-
            Whether to keep trying the remaining routing paths (e.g. alternate
            providers/gateways) for the same destination after `timeout_secs` is
            reached for the current attempt. When set to `false`, reaching
            `timeout_secs` aborts the entire dial attempt and the `call.hangup`
            webhook reports a `hangup_cause` of `no_answer` instead of
            `timeout`.
          default: true
          type: boolean
          example: true
        time_limit_secs:
          description: >-
            Sets the maximum duration of a Call Control Leg in seconds. If the
            time limit is reached, the call will hangup and a `call.hangup`
            webhook with a `hangup_cause` of `time_limit` will be sent. For
            example, by setting a time limit of 120 seconds, a Call Leg will be
            automatically terminated two minutes after being answered. The
            default time limit is 14400 seconds or 4 hours and this is also the
            maximum allowed call length.
          default: 14400
          type: integer
          example: 600
          format: int32
          minimum: 30
          maximum: 14400
        answering_machine_detection:
          description: >-
            Enables Answering Machine Detection. Telnyx offers Premium and
            Standard detections. With Premium detection, when a call is
            answered, Telnyx runs real-time detection and sends a
            `call.machine.premium.detection.ended` webhook with one of the
            following results: `human_residence`, `human_business`, `machine`,
            `silence` or `fax_detected`. If we detect a beep, we also send a
            `call.machine.premium.greeting.ended` webhook with the result of
            `beep_detected`. If we detect a beep before
            `call.machine.premium.detection.ended` we only send
            `call.machine.premium.greeting.ended`, and if we detect a beep after
            `call.machine.premium.detection.ended`, we send both webhooks. With
            Standard detection, when a call is answered, Telnyx runs real-time
            detection to determine if it was picked up by a human or a machine
            and sends an `call.machine.detection.ended` webhook with the
            analysis result. If `greeting_end` or `detect_words` is used and a
            `machine` is detected, you will receive another
            `call.machine.greeting.ended` webhook when the answering machine
            greeting ends with a beep or silence. If `detect_beep` is used, you
            will only receive `call.machine.greeting.ended` if a beep is
            detected.
          default: disabled
          type: string
          enum:
            - premium
            - detect
            - detect_beep
            - detect_words
            - greeting_end
            - disabled
        answering_machine_detection_config:
          description: >-
            Optional configuration parameters to modify
            'answering_machine_detection' performance. Only
            `total_analysis_time_millis` and `greeting_duration_millis`
            parameters are applicable when `premium` is selected as
            answering_machine_detection.
          type: object
          properties:
            total_analysis_time_millis:
              description: Maximum timeout threshold for overall detection.
              default: 3500
              type: integer
              example: 5000
              format: int32
            after_greeting_silence_millis:
              description: >-
                Silence duration threshold after a greeting message or voice for
                it be considered human.
              default: 800
              type: integer
              example: 1000
              format: int32
            between_words_silence_millis:
              description: Maximum threshold for silence between words.
              default: 50
              type: integer
              example: 100
              format: int32
            greeting_duration_millis:
              description: >-
                Maximum threshold of a human greeting. If greeting longer than
                this value, considered machine.
              default: 3500
              type: integer
              example: 1500
              format: int32
            initial_silence_millis:
              description: >-
                If initial silence duration is greater than this value, consider
                it a machine.
              default: 3500
              type: integer
              example: 1800
              format: int32
            maximum_number_of_words:
              description: >-
                If number of detected words is greater than this value, consder
                it a machine.
              default: 5
              type: integer
              example: 3
              format: int32
            maximum_word_length_millis:
              description: >-
                If a single word lasts longer than this threshold, consider it a
                machine.
              default: 3500
              type: integer
              example: 2000
              format: int32
            silence_threshold:
              description: Minimum noise threshold for any analysis.
              default: 256
              type: integer
              example: 512
              format: int32
            greeting_total_analysis_time_millis:
              description: >-
                If machine already detected, maximum timeout threshold to
                determine the end of the machine greeting.
              default: 5000
              type: integer
              example: 7500
              format: int32
            greeting_silence_duration_millis:
              description: >-
                If machine already detected, maximum threshold for silence
                between words. If exceeded, the greeting is considered ended.
              default: 1500
              type: integer
              example: 2000
              format: int32
        deepfake_detection:
          description: >-
            Enables deepfake detection on the call. When enabled, audio from the
            remote party is streamed to a detection service that analyzes
            whether the voice is AI-generated. Results are delivered via the
            `call.deepfake_detection.result` webhook.
          type: object
          required:
            - enabled
          properties:
            enabled:
              type: boolean
              default: false
              description: Whether deepfake detection is enabled.
            timeout:
              type: integer
              format: int32
              default: 15
              minimum: 5
              maximum: 60
              description: >-
                Maximum time in seconds to wait for a detection result before
                timing out.
            rtp_timeout:
              type: integer
              format: int32
              default: 30
              minimum: 5
              maximum: 120
              description: >-
                Maximum time in seconds to wait for RTP audio before timing out.
                If no audio is received within this window, detection stops with
                an error.
        conference_config:
          description: >-
            Optional configuration parameters to dial new participant into a
            conference.
          type: object
          properties:
            id:
              description: Conference ID to be joined
              type: string
              example: 0ccc7b54-4df3-4bca-a65a-3da1ecc777f0
              format: uuid
            conference_name:
              description: Conference name to be joined
              type: string
              example: telnyx-conference
            early_media:
              description: >-
                Controls the moment when dialled call is joined into conference.
                If set to `true` user will be joined as soon as media is
                available (ringback). If `false` user will be joined when call
                is answered. Defaults to `true`
              type: boolean
              example: false
              default: true
            end_conference_on_exit:
              description: >-
                Whether the conference should end and all remaining participants
                be hung up after the participant leaves the conference. Defaults
                to "false".
              example: true
              type: boolean
            soft_end_conference_on_exit:
              description: >-
                Whether the conference should end after the participant leaves
                the conference. NOTE this doesn't hang up the other
                participants. Defaults to "false".
              example: true
              type: boolean
            hold:
              description: >-
                Whether the participant should be put on hold immediately after
                joining the conference. Defaults to "false".
              example: true
              type: boolean
            hold_audio_url:
              type: string
              example: http://example.com/message.wav
              description: >-
                The URL of a file to be played to the participant when they are
                put on hold after joining the conference. hold_media_name and
                hold_audio_url cannot be used together in one request. Takes
                effect only when "start_conference_on_create" is set to "false".
                This property takes effect only if "hold" is set to "true".
            hold_media_name:
              type: string
              example: my_media_uploaded_to_media_storage_api
              description: >-
                The media_name of a file to be played to the participant when
                they are put on hold after joining the conference. The
                media_name must point to a file previously uploaded to
                api.telnyx.com/v2/media by the same user/organization. The file
                must either be a WAV or MP3 file. Takes effect only when
                "start_conference_on_create" is set to "false". This property
                takes effect only if "hold" is set to "true".
            mute:
              description: >-
                Whether the participant should be muted immediately after
                joining the conference. Defaults to "false".
              example: true
              type: boolean
            start_conference_on_enter:
              description: >-
                Whether the conference should be started after the participant
                joins the conference. Defaults to "false".
              example: true
              type: boolean
            start_conference_on_create:
              description: >-
                Whether the conference should be started on creation. If the
                conference isn't started all participants that join are
                automatically put on hold. Defaults to "true".
              example: false
              type: boolean
            supervisor_role:
              description: >-
                Sets the joining participant as a supervisor for the conference.
                A conference can have multiple supervisors. "barge" means the
                supervisor enters the conference as a normal participant. This
                is the same as "none". "monitor" means the supervisor is muted
                but can hear all participants. "whisper" means that only the
                specified "whisper_call_control_ids" can hear the supervisor.
                Defaults to "none".
              example: whisper
              type: string
              enum:
                - barge
                - monitor
                - none
                - whisper
            whisper_call_control_ids:
              description: >-
                Array of unique call_control_ids the joining supervisor can
                whisper to. If none provided, the supervisor will join the
                conference as a monitoring participant only.
              example:
                - v2:Sg1xxxQ_U3ixxxyXT_VDNI3xxxazZdg6Vxxxs4-GNYxxxVaJPOhFMRQ
                - v2:qqpb0mmvd-ovhhBr0BUQQn0fld5jIboaaX3-De0DkqXHzbf8d75xkw
              type: array
              items:
                type: string
            beep_enabled:
              description: >-
                Whether a beep sound should be played when the participant joins
                and/or leaves the conference. Can be used to override the
                conference-level setting.
              enum:
                - always
                - never
                - on_enter
                - on_exit
              example: on_exit
              type: string
        custom_headers:
          description: Custom headers to be added to the SIP INVITE.
          type: array
          example:
            - name: head_1
              value: val_1
            - name: head_2
              value: val_2
          items:
            $ref: '#/components/schemas/CustomSipHeader'
        billing_group_id:
          description: >-
            Use this field to set the Billing Group ID for the call. Must be a
            valid and existing Billing Group ID.
          type: string
          format: uuid
          example: f5586561-8ff0-4291-a0ac-84fe544797bd
        client_state:
          description: >-
            Use this field to add state to every subsequent webhook. It must be
            a valid Base-64 encoded string.
          type: string
          example: aGF2ZSBhIG5pY2UgZGF5ID1d
        command_id:
          description: >-
            Use this field to avoid duplicate commands. Telnyx will ignore
            others Dial commands with the same `command_id`.
          type: string
          example: 891510ac-f3e4-11e8-af5b-de00688a4901
        link_to:
          description: Use another call's control id for sharing the same call session id
          type: string
          example: ilditnZK_eVysupV21KzmzN_sM29ygfauQojpm4BgFtfX5hXAcjotg==
        bridge_intent:
          description: >-
            Indicates the intent to bridge this call with the call specified in
            link_to. When bridge_intent is true, link_to becomes required and
            the from number will be overwritten by the from number from the
            linked call.
          type: boolean
          default: false
          example: true
        bridge_on_answer:
          description: >-
            Whether to automatically bridge answered call to the call specified
            in link_to. When bridge_on_answer is true, link_to becomes required.
          type: boolean
          default: false
          example: true
        prevent_double_bridge:
          description: >-
            Prevents bridging and hangs up the call if the target is already
            bridged. Disabled by default.
          type: boolean
          default: false
          example: true
        park_after_unbridge:
          description: >-
            If supplied with the value `self`, the current leg will be parked
            after unbridge. If not set, the default behavior is to hang up the
            leg. When park_after_unbridge is set, link_to becomes required.
          type: string
          example: self
        media_encryption:
          description: >-
            Defines whether media should be encrypted on the call. For SIP URI
            destinations, media encryption can also be requested per endpoint
            with the `secure` URI parameter: `;secure=true` or `;secure=srtp`
            enables SRTP, and `;secure=dtls` enables DTLS. This parameter, when
            set to `SRTP` or `DTLS`, takes precedence over the per-endpoint
            `secure` value.
          default: disabled
          type: string
          enum:
            - disabled
            - SRTP
            - DTLS
        sip_auth_username:
          description: SIP Authentication username used for SIP challenges.
          type: string
        sip_auth_password:
          description: SIP Authentication password used for SIP challenges.
          type: string
        sip_headers:
          description: >-
            SIP headers to be added to the SIP INVITE request. Currently only
            User-to-User header is supported.
          type: array
          example:
            - name: User-to-User
              value: value
          items:
            $ref: '#/components/schemas/SipHeader'
        sip_transport_protocol:
          description: Defines SIP transport protocol to be used on the call.
          default: UDP
          type: string
          enum:
            - UDP
            - TCP
            - TLS
        sound_modifications:
          $ref: '#/components/schemas/SoundModifications'
        stream_url:
          description: >-
            The destination WebSocket address where the stream is going to be
            delivered.
          type: string
          example: wss://www.example.com/websocket
        stream_track:
          description: Specifies which track should be streamed.
          type: string
          enum:
            - inbound_track
            - outbound_track
            - both_tracks
          default: inbound_track
          example: both_tracks
        stream_codec:
          $ref: '#/components/schemas/StreamCodec'
        stream_bidirectional_mode:
          $ref: '#/components/schemas/StreamBidirectionalMode'
        stream_bidirectional_codec:
          $ref: '#/components/schemas/StreamBidirectionalCodec'
        stream_bidirectional_target_legs:
          $ref: '#/components/schemas/StreamBidirectionalTargetLegs'
        stream_bidirectional_sampling_rate:
          $ref: '#/components/schemas/StreamBidirectionalSamplingRate'
        stream_establish_before_call_originate:
          description: >-
            Establish websocket connection before dialing the destination. This
            is useful for cases where the websocket connection takes a long time
            to establish.
          type: boolean
          default: false
          example: true
        send_silence_when_idle:
          description: Generate silence RTP packets when no transmission available.
          type: boolean
          default: false
          example: true
        webhook_url:
          description: >-
            Use this field to override the URL for which Telnyx will send
            subsequent webhooks to for this call.
          type: string
          example: https://www.example.com/server-b/
        webhook_url_method:
          description: HTTP request type used for `webhook_url`.
          default: POST
          type: string
          enum:
            - POST
            - GET
          example: GET
        webhook_urls:
          description: >-
            A map of event types to arrays of webhook URLs. When an event of the
            specified type occurs, the webhook URLs associated with that event
            type will be called instead of the default webhook URL. Events not
            mapped here will use the default webhook URL.
          type: object
          additionalProperties:
            type: array
            items:
              type: string
              format: uri
          example:
            call.hangup:
              - https://www.example.com/webhooks/hangup
            call.bridge:
              - https://www.example.com/webhooks/bridge
        webhook_urls_method:
          description: HTTP request method to invoke `webhook_urls`.
          type: string
          enum:
            - POST
            - GET
          default: POST
          example: POST
        webhook_retries_policies:
          description: >-
            A map of event types to retry policies. Each retry policy contains
            an array of `retries_ms` specifying the delays between retry
            attempts in milliseconds. Maximum 5 retries, total delay cannot
            exceed 60 seconds.
          type: object
          additionalProperties:
            type: object
            properties:
              retries_ms:
                type: array
                items:
                  type: integer
                maxItems: 5
                description: >-
                  Array of delays in milliseconds between retry attempts. Total
                  sum cannot exceed 60000ms.
          example:
            call.hangup:
              retries_ms:
                - 1000
                - 2000
                - 5000
        record:
          description: Start recording automatically after an event. Disabled by default.
          type: string
          enum:
            - record-from-answer
          example: record-from-answer
        record_channels:
          description: >-
            Defines which channel should be recorded ('single' or 'dual') when
            `record` is specified.
          type: string
          enum:
            - single
            - dual
          default: dual
          example: single
        record_format:
          description: >-
            Defines the format of the recording ('wav' or 'mp3') when `record`
            is specified.
          type: string
          enum:
            - wav
            - mp3
          default: mp3
          example: wav
        record_max_length:
          description: >-
            Defines the maximum length for the recording in seconds when
            `record` is specified. The minimum value is 0. The maximum value is
            43200. The default value is 0 (infinite).
          type: integer
          format: int32
          default: 0
          example: 1000
        record_timeout_secs:
          description: >-
            The number of seconds that Telnyx will wait for the recording to be
            stopped if silence is detected when `record` is specified. The timer
            only starts when the speech is detected. Please note that call
            transcription is used to detect silence and the related charge will
            be applied. The minimum value is 0. The default value is 0
            (infinite).
          type: integer
          format: int32
          default: 0
          example: 100
        record_track:
          description: >-
            The audio track to be recorded. Can be either `both`, `inbound` or
            `outbound`. If only single track is specified (`inbound`,
            `outbound`), `channels` configuration is ignored and it will be
            recorded as mono (single channel).
          type: string
          example: outbound
          default: both
          enum:
            - both
            - inbound
            - outbound
        record_trim:
          description: >-
            When set to `trim-silence`, silence will be removed from the
            beginning and end of the recording.
          enum:
            - trim-silence
          type: string
          example: trim-silence
        record_custom_file_name:
          description: >-
            The custom recording file name to be used instead of the default
            `call_leg_id`. Telnyx will still add a Unix timestamp suffix.
          type: string
          minLength: 1
          maxLength: 40
          example: my_recording_file_name
        supervise_call_control_id:
          description: The call leg which will be supervised by the new call.
          type: string
          example: v3:MdI91X4lWFEs7IgbBEOT9M4AigoY08M0WWZFISt1Yw2axZ_IiE4pqg
        supervisor_role:
          description: >-
            The role of the supervisor call. 'barge' means that supervisor call
            hears and is being heard by both ends of the call (caller & callee).
            'whisper' means that only supervised_call_control_id hears
            supervisor but supervisor can hear everything. 'monitor' means that
            nobody can hear supervisor call, but supervisor can hear everything
            on the call.
          type: string
          enum:
            - barge
            - whisper
            - monitor
          default: barge
        enable_dialogflow:
          description: Enables Dialogflow for the current call. The default value is false.
          type: boolean
          default: false
          example: true
        dialogflow_config:
          $ref: '#/components/schemas/DialogflowConfig'
        transcription:
          description: Enable transcription upon call answer. The default value is false.
          type: boolean
          default: false
          example: true
        transcription_config:
          $ref: '#/components/schemas/TranscriptionStartRequest'
        sip_region:
          description: Defines the SIP region to be used for the call.
          type: string
          default: US
          enum:
            - US
            - Europe
            - Canada
            - Australia
            - Middle East
          example: Canada
        stream_auth_token:
          description: >-
            An authentication token to be sent as part of the WebSocket
            connection when using streaming. Maximum length is 4000 characters.
          type: string
          maxLength: 4000
          example: your-auth-token
        route_to_mobile:
          description: >-
            When set to true, routes the call directly to the mobile device
            associated with the destination Telnyx Mobile number, bypassing
            Inbound Calls Interception configured in the Telnyx Portal under
            Mobile Numbers → select the number → Voice → Call Interception. Use
            this when transferring an intercepted call to the mobile device to
            prevent the call from being intercepted again. Defaults to false.
          type: boolean
          default: false
          example: true
    CallWithRecordingId:
      type: object
      title: Call With Recording ID
      required:
        - call_control_id
        - call_leg_id
        - call_session_id
        - is_alive
        - record_type
      example:
        call_control_id: v3:MdI91X4lWFEs7IgbBEOT9M4AigoY08M0WWZFISt1Yw2axZ_IiE4pqg
        call_leg_id: 2dc6fc34-f9e0-11ea-b68e-02420a0f7768
        call_session_id: 2dc1b3c8-f9e0-11ea-bc5a-02420a0f7768
        client_state: aGF2ZSBhIG5pY2UgZGF5ID1d
        is_alive: false
        call_duration: 50
        record_type: call
        recording_id: d7e9c1d4-8b2a-4b8f-b3a7-9a671c9e9b0a
        start_time: '2019-01-23T18:10:02.574Z'
        end_time: '2019-01-23T18:11:52.574Z'
      properties:
        record_type:
          type: string
          enum:
            - call
          example: call
        call_session_id:
          description: >-
            ID that is unique to the call session and can be used to correlate
            webhook events. Call session is a group of related call legs that
            logically belong to the same phone call, e.g. an inbound and
            outbound leg of a transferred call
          type: string
          example: 428c31b6-7af4-4bcb-b68e-5013ef9657c1
        call_leg_id:
          description: >-
            ID that is unique to the call and can be used to correlate webhook
            events
          type: string
          example: 428c31b6-7af4-4bcb-b7f5-5013ef9657c1
        call_control_id:
          description: Unique identifier and token for controlling the call.
          type: string
          example: v3:MdI91X4lWFEs7IgbBEOT9M4AigoY08M0WWZFISt1Yw2axZ_IiE4pqg
        is_alive:
          description: >-
            Indicates whether the call is alive or not. For Dial command it will
            always be `false` (dialing is asynchronous).
          type: boolean
          example: true
        client_state:
          description: State received from a command.
          type: string
          example: aGF2ZSBhIG5pY2UgZGF5ID1d
        call_duration:
          description: Indicates the duration of the call in seconds
          type: integer
          example: 50
        recording_id:
          type: string
          format: uuid
          example: d7e9c1d4-8b2a-4b8f-b3a7-9a671c9e9b0a
          description: >-
            The ID of the recording. Only present when the record parameter is
            set to record-from-answer.
        start_time:
          description: ISO 8601 formatted date indicating when the call started
          type: string
          example: '2019-01-23T18:10:02.574Z'
        end_time:
          description: >-
            ISO 8601 formatted date indicating when the call ended. Only present
            when the call is not alive
          type: string
          example: '2019-01-23T18:11:52.574Z'
    CallAssistantRequest:
      type: object
      description: >-
        AI Assistant configuration. All fields except `id` are optional — the
        assistant's stored configuration will be used as fallback for any
        omitted fields.
      required:
        - id
      properties:
        id:
          type: string
          description: The identifier of the AI assistant to use.
        model:
          type: string
          description: >-
            LLM model override for this call. If omitted, the assistant's
            configured model is used.
          example: gpt-4o
        name:
          type: string
          description: Assistant name override for this call.
        instructions:
          type: string
          description: >-
            System instructions for the voice assistant. Can be templated with
            [dynamic
            variables](https://developers.telnyx.com/docs/inference/ai-assistants/dynamic-variables).
            This will overwrite the instructions set in the assistant
            configuration.
          example: You are a friendly voice assistant.
        greeting:
          type: string
          maxLength: 3000
          description: >-
            Initial greeting text spoken when the assistant starts. Can be plain
            text for any voice or SSML for `AWS.Polly.<voice_id>` voices. There
            is a 3,000 character limit.
        voice_settings:
          $ref: '#/components/schemas/VoiceSettings'
        tools:
          type: array
          description: >-
            Inline tool definitions available to the assistant (webhook,
            retrieval, transfer, hangup, etc.). Overrides the assistant's stored
            tools if provided.
          items:
            oneOf:
              - $ref: '#/components/schemas/BookAppointmentTool'
              - $ref: '#/components/schemas/CheckAvailabilityTool'
              - $ref: '#/components/schemas/WebhookTool'
              - $ref: '#/components/schemas/HangupTool'
              - $ref: '#/components/schemas/TransferTool'
              - $ref: '#/components/schemas/CallControlRetrievalTool'
            discriminator:
              propertyName: type
              mapping:
                book_appointment:
                  $ref: '#/components/schemas/BookAppointmentTool'
                check_availability:
                  $ref: '#/components/schemas/CheckAvailabilityTool'
                webhook:
                  $ref: '#/components/schemas/WebhookTool'
                hangup:
                  $ref: '#/components/schemas/HangupTool'
                transfer:
                  $ref: '#/components/schemas/TransferTool'
                retrieval:
                  $ref: '#/components/schemas/CallControlRetrievalTool'
        llm_api_key_ref:
          type: string
          description: >-
            Integration secret identifier for the LLM provider API key. Use this
            field to reference an [integration
            secret](https://developers.telnyx.com/api/secrets-manager/integration-secrets/create-integration-secret)
            containing your LLM provider API key. Supports any LLM provider
            (OpenAI, Anthropic, etc.).
          example: my_llm_api_key
        openai_api_key_ref:
          type: string
          description: >-
            Deprecated — use `llm_api_key_ref` instead. Integration secret
            identifier for the OpenAI API key. This field is maintained for
            backward compatibility; `llm_api_key_ref` is the canonical field
            name and supports all LLM providers.
          deprecated: true
          x-sdk-deprecation-message: Use llm_api_key_ref instead
          example: my_openai_api_key
        dynamic_variables:
          type: object
          description: >-
            Map of dynamic variables and their default values. Dynamic variables
            can be referenced in instructions, greeting, and tool definitions
            using the `{{variable_name}}` syntax. Call-control-agent
            automatically merges in `telnyx_call_*` variables (telnyx_call_to,
            telnyx_call_from, telnyx_conversation_channel, telnyx_agent_target,
            telnyx_end_user_target, telnyx_call_caller_id_name) and custom
            header variables.
          additionalProperties:
            oneOf:
              - type: string
              - type: number
              - type: boolean
          example:
            customer_name: John
            account_id: ACC-12345
        fallback_config:
          type: object
          description: >-
            Fallback LLM configuration used when the primary LLM provider is
            unavailable.
          properties:
            model:
              type: string
              description: >-
                Fallback Telnyx-hosted model to use when the primary LLM
                provider is unavailable.
            llm_api_key_ref:
              type: string
              description: Integration secret identifier for the fallback model API key.
            external_llm:
              type: object
              description: External LLM fallback configuration.
              properties:
                model:
                  type: string
                  description: Model identifier to use with the external LLM endpoint.
                base_url:
                  type: string
                  description: Base URL for the external LLM endpoint.
                llm_api_key_ref:
                  type: string
                  description: Integration secret identifier for the external LLM API key.
                authentication_method:
                  type: string
                  enum:
                    - token
                    - certificate
                  default: token
                  description: >-
                    Authentication method used when connecting to the external
                    LLM endpoint.
                certificate_ref:
                  type: string
                  description: >-
                    Integration secret identifier for the client certificate
                    used with certificate authentication.
                token_retrieval_url:
                  type: string
                  description: >-
                    URL used to retrieve an access token when certificate
                    authentication is enabled.
                forward_metadata:
                  type: boolean
                  default: false
                  description: >-
                    When enabled, Telnyx forwards the assistant's dynamic
                    variables to the external LLM endpoint. Defaults to false.
                    The chat completion request includes a top-level
                    `extra_metadata` object when dynamic variables are
                    available. For example:
                    `{"extra_metadata":{"customer_name":"Jane","account_id":"acct_789","telnyx_agent_target":"+13125550100","telnyx_end_user_target":"+13125550123"}}`.
        external_llm:
          type: object
          description: External LLM configuration for bringing your own LLM endpoint.
          properties:
            model:
              type: string
              description: Model identifier to use with the external LLM endpoint.
            base_url:
              type: string
              description: Base URL for the external LLM endpoint.
            llm_api_key_ref:
              type: string
              description: Integration secret identifier for the external LLM API key.
            authentication_method:
              type: string
              enum:
                - token
                - certificate
              default: token
              description: >-
                Authentication method used when connecting to the external LLM
                endpoint.
            certificate_ref:
              type: string
              description: >-
                Integration secret identifier for the client certificate used
                with certificate authentication.
            token_retrieval_url:
              type: string
              description: >-
                URL used to retrieve an access token when certificate
                authentication is enabled.
            forward_metadata:
              type: boolean
              default: false
              description: >-
                When enabled, Telnyx forwards the assistant's dynamic variables
                to the external LLM endpoint. Defaults to false. The chat
                completion request includes a top-level `extra_metadata` object
                when dynamic variables are available. For example:
                `{"extra_metadata":{"customer_name":"Jane","account_id":"acct_789","telnyx_agent_target":"+13125550100","telnyx_end_user_target":"+13125550123"}}`.
        mcp_servers:
          type: array
          description: >-
            MCP (Model Context Protocol) server configurations for extending the
            assistant's capabilities with external tools and data sources.
          items:
            type: object
            properties: {}
        observability_settings:
          type: object
          description: >-
            Observability configuration for the assistant session, including
            Langfuse integration for tracing and monitoring.
          properties: {}
    ConversationRelayEmbeddedConfig:
      type: object
      title: Conversation Relay Embedded Config
      description: >-
        Starts a Conversation Relay session automatically when the
        answered/dialed call is answered. This embedded shape is supported on
        `answer` and `dial`. It uses public field names (`url`,
        `dtmf_detection`, `greeting`, `voice`, `language`, etc.) and maps them
        to the underlying Conversation Relay action. `client_state`,
        `tts_language`, and `transcription_language` inside this object are
        ignored; use the parent command's `client_state` and `command_id` fields
        instead.
      properties:
        url:
          type: string
          pattern: ^wss?://
          description: >-
            WebSocket URL for your Conversation Relay server. Must start with
            `ws://` or `wss://`.
          example: wss://example.com/conversation-relay
        dtmf_detection:
          type: boolean
          description: Enable DTMF detection for the relay session.
          default: false
          example: true
        greeting:
          type: string
          description: Text played when the relay session starts.
          example: Hi! Ask me anything!
        voice:
          $ref: '#/components/schemas/VoiceConfig'
        voice_settings:
          description: The settings associated with the voice selected
          oneOf:
            - $ref: '#/components/schemas/ElevenLabsVoiceSettings'
            - $ref: '#/components/schemas/TelnyxVoiceSettings'
            - $ref: '#/components/schemas/AWSVoiceSettings'
            - $ref: '#/components/schemas/MinimaxVoiceSettings'
            - $ref: '#/components/schemas/AzureVoiceSettings'
            - $ref: '#/components/schemas/RimeVoiceSettings'
            - $ref: '#/components/schemas/ResembleVoiceSettings'
            - $ref: '#/components/schemas/InworldVoiceSettings'
            - $ref: '#/components/schemas/XAIVoiceSettings'
          discriminator:
            propertyName: type
            mapping:
              elevenlabs:
                $ref: '#/components/schemas/ElevenLabsVoiceSettings'
              telnyx:
                $ref: '#/components/schemas/TelnyxVoiceSettings'
              aws:
                $ref: '#/components/schemas/AWSVoiceSettings'
              minimax:
                $ref: '#/components/schemas/MinimaxVoiceSettings'
              azure:
                $ref: '#/components/schemas/AzureVoiceSettings'
              rime:
                $ref: '#/components/schemas/RimeVoiceSettings'
              resemble:
                $ref: '#/components/schemas/ResembleVoiceSettings'
              inworld:
                $ref: '#/components/schemas/InworldVoiceSettings'
              xai:
                $ref: '#/components/schemas/XAIVoiceSettings'
        tts_provider:
          type: string
          description: >-
            Text-to-speech provider. If omitted, Telnyx derives it from `voice`
            or `provider`.
          example: telnyx
        provider:
          type: string
          description: >-
            Structured voice provider. Must be supplied together with
            `structured_provider`.
          example: elevenlabs
        structured_provider:
          $ref: '#/components/schemas/ConversationRelayStructuredProvider'
        language:
          type: string
          description: Default language for both text-to-speech and speech recognition.
          default: en
          example: en-US
        languages:
          type: array
          description: Per-language TTS and transcription settings.
          items:
            $ref: '#/components/schemas/ConversationRelayLanguage'
        interruptible:
          $ref: '#/components/schemas/ConversationRelayInterruptible'
        interruptible_greeting:
          $ref: '#/components/schemas/ConversationRelayInterruptible'
        interruption_settings:
          $ref: '#/components/schemas/ConversationRelayInterruptionSettings'
        transcription_engine:
          description: >-
            Engine to use for speech recognition. Legacy values `A` - `Google`,
            `B` - `Telnyx` are supported for backward compatibility. For
            Conversation Relay, use this field with
            `transcription_engine_config`; the `transcription` object is not
            supported.
          type: string
          enum:
            - Google
            - Telnyx
            - Deepgram
            - Azure
            - xAI
            - AssemblyAI
            - Speechmatics
            - Soniox
            - A
            - B
          default: Google
          example: Google
        transcription_engine_config:
          $ref: '#/components/schemas/ConversationRelayTranscriptionEngineConfig'
        custom_parameters:
          type: object
          description: >-
            Custom key-value parameters forwarded to the relay session as
            assistant dynamic variables.
          additionalProperties: true
          example:
            customer_id: '12345'
      required:
        - url
      example:
        url: wss://example.com/conversation-relay
        dtmf_detection: true
        greeting: Hi! Ask me anything!
        voice: Telnyx.KokoroTTS.af
        tts_provider: telnyx
        voice_settings:
          type: telnyx
        language: en-US
        languages:
          - language: en-US
            voice: Telnyx.Ultra.alloy
            tts_provider: telnyx
            transcription_engine: Deepgram
            transcription_engine_config:
              transcription_model: deepgram/nova-3
        interruptible: speech
        interruptible_greeting: dtmf
        custom_parameters:
          customer_id: '12345'
    CustomSipHeader:
      type: object
      title: Custom SIP Header
      required:
        - name
        - value
      properties:
        name:
          description: The name of the header to add.
          type: string
          example: head_1
        value:
          description: The value of the header.
          type: string
          example: val_1
      example:
        name: head_1
        value: val_1
    SipHeader:
      type: object
      title: SIP Header
      required:
        - name
        - value
      properties:
        name:
          description: The name of the header to add.
          type: string
          enum:
            - User-to-User
          example: User-to-User
        value:
          description: The value of the header.
          type: string
          example: value
      example:
        name: User-to-User
        value: value
    SoundModifications:
      type: object
      title: Sound modifications
      description: Use this field to modify sound effects, for example adjust the pitch.
      properties:
        pitch:
          description: >-
            Set the pitch directly, value should be > 0, default 1 (lower =
            lower tone)
          type: number
          format: float
          example: 0.8
        semitone:
          description: >-
            Adjust the pitch in semitones, values should be between -14 and 14,
            default 0
          type: number
          format: float
          example: -10
        octaves:
          description: >-
            Adjust the pitch in octaves, values should be between -1 and 1,
            default 0
          type: number
          format: float
          example: -0.5
        track:
          description: >-
            The track to which the sound modifications will be applied. Accepted
            values are `inbound` or `outbound`
          type: string
          example: inbound
          default: outbound
      example:
        pitch: 0.8
        semitone: -2
        octaves: 0.1
        track: both
    StreamCodec:
      description: >-
        Specifies the codec to be used for the streamed audio. When set to
        'default' or when transcoding is not possible, the codec from the call
        will be used.
      title: Stream Codec
      type: string
      enum:
        - PCMU
        - PCMA
        - G722
        - OPUS
        - AMR-WB
        - L16
        - default
      default: default
      example: PCMA
    StreamBidirectionalMode:
      type: string
      title: Bidirectional Stream Mode
      description: Configures method of bidirectional streaming (mp3, rtp).
      enum:
        - mp3
        - rtp
      default: mp3
      example: rtp
    StreamBidirectionalCodec:
      type: string
      title: Bidirectional Stream Codec
      description: >-
        Indicates codec for bidirectional streaming RTP payloads. Used only with
        stream_bidirectional_mode=rtp. Case sensitive.
      enum:
        - PCMU
        - PCMA
        - G722
        - OPUS
        - AMR-WB
        - L16
      default: PCMU
      example: G722
    StreamBidirectionalTargetLegs:
      type: string
      title: Bidirectional Stream Target Legs
      description: Specifies which call legs should receive the bidirectional stream audio.
      enum:
        - both
        - self
        - opposite
      default: opposite
      example: both
    StreamBidirectionalSamplingRate:
      type: integer
      title: Bidirectional Stream Sampling Rate
      description: Audio sampling rate.
      enum:
        - 8000
        - 16000
        - 22050
        - 24000
        - 48000
      default: 8000
      example: 16000
    DialogflowConfig:
      type: object
      title: Dialogflow Config
      properties:
        analyze_sentiment:
          description: Enable sentiment analysis from Dialogflow.
          type: boolean
          example: true
          default: false
        partial_automated_agent_reply:
          description: Enable partial automated agent reply from Dialogflow.
          type: boolean
          example: true
          default: false
    TranscriptionStartRequest:
      type: object
      title: Transcription start request
      properties:
        transcription_engine:
          description: >-
            Engine to use for speech recognition. Legacy values `A` - `Google`,
            `B` - `Telnyx` are supported for backward compatibility.
          type: string
          enum:
            - Google
            - Telnyx
            - Deepgram
            - Azure
            - xAI
            - AssemblyAI
            - Speechmatics
            - Soniox
            - Parakeet
            - Humain
            - Reson8
            - A
            - B
          default: Google
          example: Google
        transcription_engine_config:
          oneOf:
            - $ref: '#/components/schemas/TranscriptionEngineGoogleConfig'
            - $ref: '#/components/schemas/TranscriptionEngineTelnyxConfig'
            - $ref: '#/components/schemas/TranscriptionEngineDeepgramConfig'
            - $ref: '#/components/schemas/TranscriptionEngineAzureConfig'
            - $ref: '#/components/schemas/TranscriptionEngineXaiConfig'
            - $ref: '#/components/schemas/TranscriptionEngineAssemblyaiConfig'
            - $ref: '#/components/schemas/TranscriptionEngineSpeechmaticsConfig'
            - $ref: '#/components/schemas/TranscriptionEngineSonioxConfig'
            - $ref: '#/components/schemas/TranscriptionEngineParakeetConfig'
            - $ref: '#/components/schemas/TranscriptionEngineHumainConfig'
            - $ref: '#/components/schemas/TranscriptionEngineReson8Config'
            - $ref: '#/components/schemas/TranscriptionEngineAConfig'
            - $ref: '#/components/schemas/TranscriptionEngineBConfig'
          discriminator:
            propertyName: transcription_engine
            mapping:
              Google:
                $ref: '#/components/schemas/TranscriptionEngineGoogleConfig'
              Telnyx:
                $ref: '#/components/schemas/TranscriptionEngineTelnyxConfig'
              Deepgram:
                $ref: '#/components/schemas/TranscriptionEngineDeepgramConfig'
              Azure:
                $ref: '#/components/schemas/TranscriptionEngineAzureConfig'
              xAI:
                $ref: '#/components/schemas/TranscriptionEngineXaiConfig'
              AssemblyAI:
                $ref: '#/components/schemas/TranscriptionEngineAssemblyaiConfig'
              Speechmatics:
                $ref: '#/components/schemas/TranscriptionEngineSpeechmaticsConfig'
              Soniox:
                $ref: '#/components/schemas/TranscriptionEngineSonioxConfig'
              Parakeet:
                $ref: '#/components/schemas/TranscriptionEngineParakeetConfig'
              Humain:
                $ref: '#/components/schemas/TranscriptionEngineHumainConfig'
              Reson8:
                $ref: '#/components/schemas/TranscriptionEngineReson8Config'
              A:
                $ref: '#/components/schemas/TranscriptionEngineAConfig'
              B:
                $ref: '#/components/schemas/TranscriptionEngineBConfig'
        client_state:
          description: >-
            Use this field to add state to every subsequent webhook. It must be
            a valid Base-64 encoded string.
          type: string
          example: aGF2ZSBhIG5pY2UgZGF5ID1d
        transcription_tracks:
          description: >-
            Indicates which leg of the call will be transcribed. Use `inbound`
            for the leg that requested the transcription, `outbound` for the
            other leg, and `both` for both legs of the call. Will default to
            `inbound`.
          type: string
          example: both
          default: inbound
        command_id:
          description: >-
            Use this field to avoid duplicate commands. Telnyx will ignore any
            command with the same `command_id` for the same `call_control_id`.
          type: string
          example: 891510ac-f3e4-11e8-af5b-de00688a4901
      example:
        transcription_engine: Google
        transcription_engine_config:
          transcription_engine: Google
          language: en
        client_state: aGF2ZSBhIG5pY2UgZGF5ID1d
        command_id: 891510ac-f3e4-11e8-af5b-de00688a4901
    Errors:
      properties:
        errors:
          type: array
          items:
            $ref: '#/components/schemas/Error'
    VoiceSettings:
      properties:
        voice:
          type: string
          description: >-
            The voice to be used by the voice assistant. Check the full list of
            [available
            voices](https://developers.telnyx.com/docs/tts-stt/tts-available-voices)
            via our voices API.

            To use ElevenLabs, you must reference your ElevenLabs API key as an
            integration secret under the `api_key_ref` field. See [integration
            secrets
            documentation](https://developers.telnyx.com/api-reference/integration-secrets/create-a-secret)
            for details. For Telnyx voices, use `Telnyx.<model_id>.<voice_id>`
            (e.g. Telnyx.KokoroTTS.af_heart).

            The voice portion of the identifier supports [dynamic
            variables](https://developers.telnyx.com/docs/inference/ai-assistants/dynamic-variables)
            using mustache syntax (e.g. `Telnyx.Ultra.{{voice_id}}`). The
            variable is resolved at call time from your dynamic variables
            webhook, allowing you to select the voice dynamically per call.
        voice_speed:
          type: number
          default: 1
          description: >-
            The speed of the voice in the range [0.25, 2.0]. 1.0 is deafult
            speed. Larger numbers make the voice faster, smaller numbers make it
            slower. This is only applicable for Telnyx Natural voices.
        api_key_ref:
          type: string
          description: >-
            The `identifier` for an integration secret
            [/v2/integration_secrets](https://developers.telnyx.com/api-reference/integration-secrets/create-a-secret)
            that refers to your ElevenLabs API key. Warning: Free plans are
            unlikely to work with this integration.
        temperature:
          type: number
          default: 0.5
          description: >-
            Determines how stable the voice is and the randomness between each
            generation. Lower values create a broader emotional range; higher
            values produce more consistent, monotonous output. Only applicable
            when using ElevenLabs.
        similarity_boost:
          type: number
          default: 0.75
          description: >-
            Determines how closely the AI should adhere to the original voice
            when attempting to replicate it. Only applicable when using
            ElevenLabs.
        use_speaker_boost:
          type: boolean
          default: true
          description: >-
            Amplifies similarity to the original speaker voice. Increases
            computational load and latency slightly. Only applicable when using
            ElevenLabs.
        style:
          type: number
          default: 0
          description: >-
            Determines the style exaggeration of the voice. Amplifies speaker
            style but consumes additional resources when set above 0. Only
            applicable when using ElevenLabs.
        speed:
          type: number
          default: 1
          description: >-
            Adjusts speech velocity. 1.0 is default speed; values less than 1.0
            slow speech; values greater than 1.0 accelerate it. Only applicable
            when using ElevenLabs.
        language_boost:
          type:
            - string
            - 'null'
          description: >-
            Enhances recognition for specific languages and dialects during
            MiniMax TTS synthesis. Default is null (no boost). Set to 'auto' for
            automatic language detection. Only applicable when using MiniMax
            voices.
          enum:
            - null
            - auto
            - Chinese
            - Chinese,Yue
            - English
            - Arabic
            - Russian
            - Spanish
            - French
            - Portuguese
            - German
            - Turkish
            - Dutch
            - Ukrainian
            - Vietnamese
            - Indonesian
            - Japanese
            - Italian
            - Korean
            - Thai
            - Polish
            - Romanian
            - Greek
            - Czech
            - Finnish
            - Hindi
            - Bulgarian
            - Danish
            - Hebrew
            - Malay
            - Persian
            - Slovak
            - Swedish
            - Croatian
            - Filipino
            - Hungarian
            - Norwegian
            - Slovenian
            - Catalan
            - Nynorsk
            - Tamil
            - Afrikaans
          default: null
        expressive_mode:
          type: boolean
          default: false
          description: >-
            Enables emotionally expressive speech using SSML emotion tags. When
            enabled, the assistant uses audio tags like angry, excited, content,
            and sad to add emotional nuance. Only supported for Telnyx Ultra
            voices.
        background_audio:
          description: >-
            Optional background audio to play on the call. Use a predefined
            media bed, or supply a looped MP3 URL. If a media URL is chosen in
            the portal, customers can preview it before saving.
          oneOf:
            - type: object
              properties:
                type:
                  type: string
                  enum:
                    - predefined_media
                  description: Select from predefined media options.
                value:
                  type: string
                  enum:
                    - silence
                    - office
                  default: silence
                  description: >-
                    The predefined media to use. `silence` disables background
                    audio.
                volume:
                  type: number
                  minimum: 0.1
                  maximum: 1
                  multipleOf: 0.1
                  default: 1
                  description: >-
                    Volume level for the predefined background audio. Supports
                    values from 0.1 to 1.0 in 0.1 increments.
              required:
                - type
                - value
            - type: object
              properties:
                type:
                  type: string
                  enum:
                    - media_url
                  description: >-
                    Provide a direct URL to an MP3 file. The audio will loop
                    during the call.
                value:
                  type: string
                  format: uri
                  description: HTTPS URL to an MP3 file.
              required:
                - type
                - value
            - type: object
              properties:
                type:
                  type: string
                  enum:
                    - media_name
                  description: >-
                    Reference a previously uploaded media by its name from
                    Telnyx Media Storage.
                value:
                  type: string
                  description: >-
                    The `name` of a media asset created via [Media Storage
                    API](https://developers.telnyx.com/api/media-storage/create-media-storage).
                    The audio will loop during the call.
              required:
                - type
                - value
      type: object
      required:
        - voice
    BookAppointmentTool:
      properties:
        type:
          type: string
          enum:
            - book_appointment
        book_appointment:
          $ref: '#/components/schemas/BookAppointmentToolParams'
      type: object
      required:
        - type
        - book_appointment
      title: BookAppointmentTool
    CheckAvailabilityTool:
      properties:
        type:
          type: string
          enum:
            - check_availability
        check_availability:
          $ref: '#/components/schemas/CheckAvailabilityToolParams'
      type: object
      required:
        - type
        - check_availability
      title: CheckAvailabilityTool
    WebhookTool:
      properties:
        type:
          type: string
          enum:
            - webhook
        webhook:
          $ref: '#/components/schemas/CallControlWebhookToolParams'
      type: object
      required:
        - type
        - webhook
      title: WebhookTool
    HangupTool:
      properties:
        type:
          type: string
          enum:
            - hangup
        hangup:
          $ref: '#/components/schemas/HangupToolParams'
      type: object
      required:
        - type
        - hangup
      title: HangupTool
    TransferTool:
      properties:
        type:
          type: string
          enum:
            - transfer
        transfer:
          $ref: '#/components/schemas/CallControlTransferToolParams'
      type: object
      required:
        - type
        - transfer
      title: TransferTool
    CallControlRetrievalTool:
      properties:
        type:
          type: string
          enum:
            - retrieval
        retrieval:
          $ref: '#/components/schemas/CallControlBucketIds'
      type: object
      required:
        - type
        - retrieval
      title: RetrievalTool
    VoiceConfig:
      description: >-
        The voice to be used by the voice assistant. Currently we support
        ElevenLabs, Telnyx and AWS voices.

         **Supported Providers:**
        - **AWS:** Use `AWS.Polly.<VoiceId>` (e.g., `AWS.Polly.Joanna`). For
        neural voices, which provide more realistic, human-like speech, append
        `-Neural` to the `VoiceId` (e.g., `AWS.Polly.Joanna-Neural`). Check the
        [available
        voices](https://docs.aws.amazon.com/polly/latest/dg/available-voices.html)
        for compatibility.

        - **Azure:** Use `Azure.<VoiceId>. (e.g. Azure.en-CA-ClaraNeural,
        Azure.en-CA-LiamNeural, Azure.en-US-BrianMultilingualNeural,
        Azure.en-US-Ava:DragonHDLatestNeural. For a complete list of voices, go
        to [Azure Voice
        Gallery](https://speech.microsoft.com/portal/voicegallery).)

        - **ElevenLabs:** Use `ElevenLabs.<ModelId>.<VoiceId>` (e.g.,
        `ElevenLabs.BaseModel.John`). The `ModelId` part is optional. To use
        ElevenLabs, you must provide your ElevenLabs API key as an integration
        secret under `"voice_settings": {"api_key_ref": "<secret_id>"}`. See
        [integration secrets
        documentation](https://developers.telnyx.com/api/secrets-manager/integration-secrets/create-integration-secret)
        for details. Check [available
        voices](https://elevenlabs.io/docs/api-reference/get-voices).
         - **Telnyx:** Use `Telnyx.<model_id>.<voice_id>`
        - **Inworld:** Use `Inworld.<ModelId>.<VoiceId>` (e.g.,
        `Inworld.Mini.Loretta`, `Inworld.Max.Oliver`, `Inworld.TTS2.Loretta`).
        Supported models: `Mini`, `Max`, `TTS2`.

        - **Fish Audio:** Use `FishAudio.<ModelId>.<VoiceId>` (e.g.,
        `FishAudio.s2.1-pro.<reference_id>`). Supported models: `s2.1-pro`,
        `s2-pro`, `s1`. `VoiceId` is a Fish Voice-Library reference ID.

        - **xAI:** Use `xAI.<VoiceId>` (e.g., `xAI.eve`). Available voices:
        `eve`, `ara`, `rex`, `sal`, `leo`.

        - **Humain:** Use `Humain.<VoiceId>` (e.g., `Humain.sara-ar`). Available
        voices: `sara-en`, `abdulaziz-en`, `sara-ar`, `abdulaziz-ar`,
        `nourah-ar`, `abdullah-ar`. Native Arabic (Saudi dialect) and English
        voices only — no `ModelId` segment.
      type: string
      default: Telnyx.KokoroTTS.af
      example: Telnyx.KokoroTTS.af
    ElevenLabsVoiceSettings:
      type: object
      title: ElevenLabs Voice Settings
      properties:
        type:
          type: string
          enum:
            - elevenlabs
          description: Voice settings provider type
        api_key_ref:
          description: >-
            The `identifier` for an integration secret
            [/v2/integration_secrets](https://developers.telnyx.com/api/secrets-manager/integration-secrets/create-integration-secret)
            that refers to your ElevenLabs API key. Warning: Free plans are
            unlikely to work with this integration.
          type: string
          example: my_elevenlabs_api_key
      required:
        - type
    TelnyxVoiceSettings:
      type: object
      title: Telnyx Voice Settings
      properties:
        type:
          type: string
          enum:
            - telnyx
          description: Voice settings provider type
        voice_speed:
          description: >-
            The voice speed to be used for the voice. The voice speed must be
            between 0.1 and 2.0. Default value is 1.0. Not supported for
            `Telnyx.Bayan.*` or `Telnyx.Sukhan.*` voices.
          type: number
          default: 1
          format: float
          example: 1
          minimum: 0.1
          maximum: 2
      required:
        - type
    AWSVoiceSettings:
      type: object
      title: AWS Voice Settings
      properties:
        type:
          type: string
          enum:
            - aws
          description: Voice settings provider type
      required:
        - type
    MinimaxVoiceSettings:
      type: object
      title: Minimax Voice Settings
      properties:
        type:
          type: string
          enum:
            - minimax
          description: Voice settings provider type
        speed:
          description: Speech speed multiplier. Default is 1.0.
          type: number
          format: float
          example: 1
          default: 1
        vol:
          description: Speech volume multiplier. Default is 1.0.
          type: number
          format: float
          example: 1
          default: 1
        pitch:
          description: Voice pitch adjustment. Default is 0.
          type: integer
          example: 0
          default: 0
        language_boost:
          type:
            - string
            - 'null'
          description: >-
            Enhances recognition for specific languages and dialects during
            MiniMax TTS synthesis. Default is null (no boost). Set to 'auto' for
            automatic language detection.
          enum:
            - null
            - auto
            - Chinese
            - Chinese,Yue
            - English
            - Arabic
            - Russian
            - Spanish
            - French
            - Portuguese
            - German
            - Turkish
            - Dutch
            - Ukrainian
            - Vietnamese
            - Indonesian
            - Japanese
            - Italian
            - Korean
            - Thai
            - Polish
            - Romanian
            - Greek
            - Czech
            - Finnish
            - Hindi
            - Bulgarian
            - Danish
            - Hebrew
            - Malay
            - Persian
            - Slovak
            - Swedish
            - Croatian
            - Filipino
            - Hungarian
            - Norwegian
            - Slovenian
            - Catalan
            - Nynorsk
            - Tamil
            - Afrikaans
          default: null
      required:
        - type
    AzureVoiceSettings:
      type: object
      title: Azure Voice Settings
      properties:
        type:
          type: string
          enum:
            - azure
          description: Voice settings provider type
        api_key_ref:
          description: >-
            The `identifier` for an integration secret that refers to your Azure
            Speech API key.
          type: string
          example: my_azure_api_key
        region:
          description: >-
            The Azure region for the Speech service (e.g., `eastus`,
            `westeurope`). Required when using a custom API key.
          type: string
          example: eastus
        deployment_id:
          description: The deployment ID for a custom Azure neural voice.
          type: string
          example: my-custom-voice-deployment
        effect:
          description: Audio effect to apply.
          type: string
          enum:
            - eq_car
            - eq_telecomhp8k
        gender:
          description: Voice gender filter.
          type: string
          enum:
            - Male
            - Female
      required:
        - type
    RimeVoiceSettings:
      type: object
      title: Rime Voice Settings
      properties:
        type:
          type: string
          enum:
            - rime
          description: Voice settings provider type
        voice_speed:
          description: Speech speed multiplier. Default is 1.0.
          type: number
          format: float
          example: 1
          default: 1
      required:
        - type
    ResembleVoiceSettings:
      type: object
      title: Resemble Voice Settings
      properties:
        type:
          type: string
          enum:
            - resemble
          description: Voice settings provider type
        precision:
          description: Audio precision format.
          type: string
          enum:
            - PCM_16
            - PCM_24
            - PCM_32
            - MULAW
          default: PCM_32
        sample_rate:
          $ref: '#/components/schemas/ResembleSampleRate'
        format:
          description: Output audio format.
          type: string
          enum:
            - wav
            - mp3
          default: mp3
      required:
        - type
    InworldVoiceSettings:
      type: object
      title: Inworld Voice Settings
      properties:
        type:
          type: string
          enum:
            - inworld
          description: Voice settings provider type
        delivery_mode:
          type: string
          enum:
            - STABLE
            - BALANCED
            - CREATIVE
          description: >-
            Controls the expressiveness and consistency of the Inworld `TTS2`
            model's speech synthesis. `STABLE` favors consistent, predictable
            output, `CREATIVE` allows more expressive variation, and `BALANCED`
            sits in between. Optional and only supported by `TTS2`; when
            omitted, the provider default applies.
      required:
        - type
    XAIVoiceSettings:
      type: object
      title: xAI Voice Settings
      properties:
        type:
          type: string
          enum:
            - xai
          description: Voice settings provider type
        language:
          description: Language code, or `auto` to detect automatically.
          type: string
          default: auto
      required:
        - type
    ConversationRelayStructuredProvider:
      type: object
      title: Conversation Relay Structured Provider
      description: >-
        Provider-specific structured voice settings. Must be supplied together
        with `provider`; Telnyx sends the value as the nested provider
        configuration for Conversation Relay.
      additionalProperties: true
      example:
        voice_id: voice-id
        model_id: Default
    ConversationRelayLanguage:
      type: object
      title: Conversation Relay Language
      description: Language-specific TTS and transcription settings for Conversation Relay.
      properties:
        language:
          type: string
          description: BCP 47 language tag for this language configuration.
          example: en-US
        tts_provider:
          type: string
          description: >-
            Text-to-speech provider for this language. If omitted and `voice` is
            provided, Telnyx derives the provider from the voice identifier.
          example: telnyx
        voice:
          type: string
          description: Voice identifier for this language.
          example: Telnyx.KokoroTTS.af
        voice_settings:
          description: The settings associated with the voice selected
          oneOf:
            - $ref: '#/components/schemas/ElevenLabsVoiceSettings'
            - $ref: '#/components/schemas/TelnyxVoiceSettings'
            - $ref: '#/components/schemas/AWSVoiceSettings'
            - $ref: '#/components/schemas/MinimaxVoiceSettings'
            - $ref: '#/components/schemas/AzureVoiceSettings'
            - $ref: '#/components/schemas/RimeVoiceSettings'
            - $ref: '#/components/schemas/ResembleVoiceSettings'
            - $ref: '#/components/schemas/InworldVoiceSettings'
            - $ref: '#/components/schemas/XAIVoiceSettings'
          discriminator:
            propertyName: type
            mapping:
              elevenlabs:
                $ref: '#/components/schemas/ElevenLabsVoiceSettings'
              telnyx:
                $ref: '#/components/schemas/TelnyxVoiceSettings'
              aws:
                $ref: '#/components/schemas/AWSVoiceSettings'
              minimax:
                $ref: '#/components/schemas/MinimaxVoiceSettings'
              azure:
                $ref: '#/components/schemas/AzureVoiceSettings'
              rime:
                $ref: '#/components/schemas/RimeVoiceSettings'
              resemble:
                $ref: '#/components/schemas/ResembleVoiceSettings'
              inworld:
                $ref: '#/components/schemas/InworldVoiceSettings'
              xai:
                $ref: '#/components/schemas/XAIVoiceSettings'
        transcription_engine:
          description: >-
            Engine to use for speech recognition. Legacy values `A` - `Google`,
            `B` - `Telnyx` are supported for backward compatibility. When
            provided in a Conversation Relay language entry, Telnyx derives
            `transcription_provider` and `speech_model` for that language.
          type: string
          enum:
            - Google
            - Telnyx
            - Deepgram
            - Azure
            - xAI
            - AssemblyAI
            - Speechmatics
            - Soniox
            - A
            - B
          default: Google
          example: Google
        transcription_engine_config:
          $ref: '#/components/schemas/ConversationRelayTranscriptionEngineConfig'
        transcription_provider:
          type: string
          description: >-
            Conversation Relay transcription provider name. Prefer
            `transcription_engine` when configuring speech-to-text.
          example: Deepgram
        speech_model:
          type: string
          description: >-
            Conversation Relay speech model. Prefer
            `transcription_engine_config.transcription_model` when configuring
            speech-to-text.
          example: nova-3
      required:
        - language
    ConversationRelayInterruptible:
      type: string
      description: >-
        Controls when caller input can interrupt assistant speech. `any` allows
        speech or DTMF interruptions; `none` disables interruptions; `speech`
        allows speech only; `dtmf` allows DTMF only.
      enum:
        - none
        - any
        - speech
        - dtmf
      default: any
      example: speech
    ConversationRelayInterruptionSettings:
      type: object
      title: Conversation Relay Interruption Settings
      description: >-
        Settings for handling caller interruptions during Conversation Relay
        speech.
      properties:
        enable:
          type: boolean
          description: >-
            Legacy boolean form. `true` is equivalent to `interruptible=any`;
            `false` is equivalent to `interruptible=none`.
        interruptible:
          $ref: '#/components/schemas/ConversationRelayInterruptible'
        interruptible_greeting:
          $ref: '#/components/schemas/ConversationRelayInterruptible'
        welcome_greeting_interruptible:
          $ref: '#/components/schemas/ConversationRelayInterruptible'
    ConversationRelayTranscriptionEngineConfig:
      type: object
      title: Conversation Relay Transcription Engine Config
      description: >-
        Engine-specific transcription settings for Conversation Relay. This
        accepts the same provider-specific options used by the Call
        Transcription Start command, such as `transcription_model`, without
        requiring the engine discriminator to be repeated inside this object.
      additionalProperties: true
      example:
        transcription_model: deepgram/nova-3
        interim_results: true
        keywords_boosting:
          telnyx: 2
    TranscriptionEngineGoogleConfig:
      type: object
      title: Transcription engine Google config
      properties:
        transcription_engine:
          type: string
          enum:
            - Google
          description: Engine identifier for Google transcription service
        language:
          $ref: '#/components/schemas/GoogleTranscriptionLanguage'
        interim_results:
          type: boolean
          description: >-
            Whether to send also interim results. If set to false, only final
            results will be sent.
          default: false
          example: true
        enable_speaker_diarization:
          type: boolean
          description: Enables speaker diarization.
          default: false
          example: true
        min_speaker_count:
          description: Defines minimum number of speakers in the conversation.
          type: integer
          example: 4
          default: 2
          format: int32
        max_speaker_count:
          description: Defines maximum number of speakers in the conversation.
          type: integer
          example: 4
          default: 6
          format: int32
        profanity_filter:
          description: Enables profanity_filter.
          type: boolean
          default: false
          example: true
        use_enhanced:
          description: >-
            Enables enhanced transcription, this works for models `phone_call`
            and `video`.
          type: boolean
          default: false
          example: true
        model:
          description: The model to use for transcription.
          type: string
          enum:
            - latest_long
            - latest_short
            - command_and_search
            - phone_call
            - video
            - default
            - medical_conversation
            - medical_dictation
        hints:
          description: Hints to improve transcription accuracy.
          type: array
          items:
            type: string
          default: []
          example: []
        speech_context:
          description: Speech context to improve transcription accuracy.
          type: array
          items:
            type: object
            properties:
              phrases:
                type: array
                items:
                  type: string
                default: []
                example: []
              boost:
                type: number
                description: Boost factor for the speech context.
                default: 1
                minimum: 0
                maximum: 20
                example: 1
    TranscriptionEngineTelnyxConfig:
      type: object
      title: Transcription engine Telnyx config
      properties:
        transcription_engine:
          type: string
          enum:
            - Telnyx
          description: Engine identifier for Telnyx transcription service
        language:
          $ref: '#/components/schemas/TelnyxTranscriptionLanguage'
        transcription_model:
          description: The model to use for transcription.
          type: string
          enum:
            - openai/whisper-tiny
            - openai/whisper-large-v3-turbo
          default: openai/whisper-tiny
    TranscriptionEngineDeepgramConfig:
      oneOf:
        - $ref: '#/components/schemas/DeepgramNova2Config'
        - $ref: '#/components/schemas/DeepgramNova3Config'
      discriminator:
        propertyName: transcription_model
        mapping:
          deepgram/nova-2:
            $ref: '#/components/schemas/DeepgramNova2Config'
          deepgram/nova-3:
            $ref: '#/components/schemas/DeepgramNova3Config'
    TranscriptionEngineAzureConfig:
      type: object
      title: Transcription engine Azure config
      properties:
        transcription_engine:
          type: string
          enum:
            - Azure
          description: Engine identifier for Azure transcription service
        language:
          $ref: '#/components/schemas/AzureTranscriptionLanguage'
        region:
          $ref: '#/components/schemas/AzureTranscriptionRegion'
        api_key_ref:
          type: string
          description: >-
            Reference to the API key for authentication. See [integration
            secrets
            documentation](https://developers.telnyx.com/api/secrets-manager/integration-secrets/create-integration-secret)
            for details. The parameter is optional as defaults are available for
            some regions.
      required:
        - transcription_engine
        - region
    TranscriptionEngineXaiConfig:
      type: object
      title: Transcription engine xAI config
      properties:
        transcription_engine:
          type: string
          enum:
            - xAI
          description: Engine identifier for xAI transcription service
        language:
          $ref: '#/components/schemas/XaiTranscriptionLanguage'
        transcription_model:
          description: The model to use for transcription.
          type: string
          enum:
            - xai/grok-stt
          default: xai/grok-stt
        interim_results:
          type: boolean
          description: >-
            Whether to send also interim results. If set to false, only final
            results will be sent.
          default: false
          example: true
    TranscriptionEngineAssemblyaiConfig:
      type: object
      title: Transcription engine AssemblyAI config
      properties:
        transcription_engine:
          type: string
          enum:
            - AssemblyAI
          description: Engine identifier for AssemblyAI transcription service
        transcription_model:
          description: The model to use for transcription.
          type: string
          enum:
            - assemblyai/universal-streaming
          default: assemblyai/universal-streaming
        interim_results:
          type: boolean
          description: >-
            Whether to send also interim results. If set to false, only final
            results will be sent.
          default: false
          example: true
    TranscriptionEngineSpeechmaticsConfig:
      type: object
      title: Transcription engine Speechmatics config
      properties:
        transcription_engine:
          type: string
          enum:
            - Speechmatics
          description: Engine identifier for Speechmatics transcription service
        language:
          $ref: '#/components/schemas/SpeechmaticsTranscriptionLanguage'
        transcription_model:
          description: The model to use for transcription.
          type: string
          enum:
            - speechmatics/standard
          default: speechmatics/standard
        interim_results:
          type: boolean
          description: >-
            Whether to send also interim results. If set to false, only final
            results will be sent.
          default: false
          example: true
    TranscriptionEngineSonioxConfig:
      type: object
      title: Transcription engine Soniox config
      required:
        - transcription_engine
      properties:
        transcription_engine:
          type: string
          enum:
            - Soniox
          description: Engine identifier for Soniox transcription service
        transcription_model:
          description: The model to use for transcription.
          type: string
          enum:
            - soniox/stt-rt-v4
          default: soniox/stt-rt-v4
        language:
          type: string
          description: >-
            ISO 639-1 language hint (e.g. `en`, `es`), or `auto` to omit the
            hint and let Soniox auto-detect supported languages multilingually.
          default: auto
          example: auto
        interim_results:
          type: boolean
          description: >-
            Whether to send also interim results. If set to false, only final
            results will be sent.
          default: false
          example: true
        enable_endpoint_detection:
          type: boolean
          description: >-
            When true, Soniox emits end-of-utterance events at the cadence
            configured by `max_endpoint_delay_ms`.
          default: false
          example: false
        max_endpoint_delay_ms:
          type: integer
          minimum: 500
          maximum: 3000
          description: >-
            Maximum silence (in milliseconds) before Soniox emits an
            end-of-utterance event. Only honored when
            `enable_endpoint_detection` is true. Range: 500-3000 ms.
          example: 1000
    TranscriptionEngineParakeetConfig:
      type: object
      title: Transcription engine Parakeet config
      properties:
        transcription_engine:
          type: string
          enum:
            - Parakeet
          description: Engine identifier for Parakeet transcription service
        transcription_model:
          description: The model to use for transcription.
          type: string
          enum:
            - nvidia/parakeet-v3
          default: nvidia/parakeet-v3
        interim_results:
          type: boolean
          description: >-
            Whether to send also interim results. If set to false, only final
            results will be sent.
          default: false
          example: true
    TranscriptionEngineHumainConfig:
      type: object
      title: Transcription engine Humain config
      properties:
        transcription_engine:
          type: string
          enum:
            - Humain
          description: Engine identifier for Humain transcription service
        transcription_model:
          description: The model to use for transcription.
          type: string
          enum:
            - humain/realtime
          default: humain/realtime
        language:
          type: string
          description: >-
            The language of the audio to be transcribed. `codeswitch` enables
            Arabic/English code-switching. `auto` resolves server-side to
            code-switching.
          enum:
            - ar
            - en
            - codeswitch
            - auto
          default: en
          example: en
    TranscriptionEngineReson8Config:
      type: object
      title: Transcription engine Reson8 config
      properties:
        transcription_engine:
          type: string
          enum:
            - Reson8
          description: Engine identifier for Reson8 transcription service
        transcription_model:
          description: The model to use for transcription.
          type: string
          enum:
            - reson8/turns
          default: reson8/turns
        language:
          type: string
          description: >-
            The language of the audio to be transcribed. `auto` (the default,
            also applied when `language` is omitted) enables automatic language
            detection.
          enum:
            - auto
            - nl
            - en
            - fr
            - fy
            - de
            - it
            - pl
            - pt
            - es
            - sv
          default: auto
          example: auto
    TranscriptionEngineAConfig:
      type: object
      title: Transcription engine A config
      properties:
        transcription_engine:
          type: string
          enum:
            - A
          description: Engine identifier for Google transcription service
        language:
          $ref: '#/components/schemas/GoogleTranscriptionLanguage'
        interim_results:
          type: boolean
          description: >-
            Whether to send also interim results. If set to false, only final
            results will be sent.
          default: false
          example: true
        enable_speaker_diarization:
          type: boolean
          description: Enables speaker diarization.
          default: false
          example: true
        min_speaker_count:
          description: Defines minimum number of speakers in the conversation.
          type: integer
          example: 4
          default: 2
          format: int32
        max_speaker_count:
          description: Defines maximum number of speakers in the conversation.
          type: integer
          example: 4
          default: 6
          format: int32
        profanity_filter:
          description: Enables profanity_filter.
          type: boolean
          default: false
          example: true
        use_enhanced:
          description: >-
            Enables enhanced transcription, this works for models `phone_call`
            and `video`.
          type: boolean
          default: false
          example: true
        model:
          description: The model to use for transcription.
          type: string
          enum:
            - latest_long
            - latest_short
            - command_and_search
            - phone_call
            - video
            - default
            - medical_conversation
            - medical_dictation
        hints:
          description: Hints to improve transcription accuracy.
          type: array
          items:
            type: string
          default: []
          example:
            - Telnyx
        speech_context:
          description: Speech context to improve transcription accuracy.
          type: array
          items:
            type: object
            properties:
              phrases:
                type: array
                items:
                  type: string
                default: []
                example:
                  - Telnyx
              boost:
                type: number
                description: Boost factor for the speech context.
                default: 1
                minimum: 0
                maximum: 20
                example: 1
    TranscriptionEngineBConfig:
      type: object
      title: Transcription engine B config
      properties:
        transcription_engine:
          type: string
          enum:
            - B
          description: Engine identifier for Telnyx transcription service
        language:
          $ref: '#/components/schemas/TelnyxTranscriptionLanguage'
        transcription_model:
          description: The model to use for transcription.
          type: string
          enum:
            - openai/whisper-tiny
            - openai/whisper-large-v3-turbo
          default: openai/whisper-tiny
    Error:
      required:
        - code
        - title
      properties:
        code:
          type: string
          format: integer
        title:
          type: string
        detail:
          type: string
        source:
          type: object
          properties:
            pointer:
              description: JSON pointer (RFC6901) to the offending entity.
              type: string
              format: json-pointer
            parameter:
              description: Indicates which query parameter caused the error.
              type: string
        meta:
          type: object
    BookAppointmentToolParams:
      properties:
        event_type_id:
          type: integer
          description: >-
            Event Type ID for which slots are being fetched.
            [cal.com](https://cal.com/docs/api-reference/v2/bookings/create-a-booking#body-event-type-id)
        api_key_ref:
          type: string
          description: >-
            Reference to an integration secret that contains your Cal.com API
            key. You would pass the `identifier` for an integration secret
            [/v2/integration_secrets](https://developers.telnyx.com/api/secrets-manager/integration-secrets/create-integration-secret)
            that refers to your Cal.com API key.
          example: my_calcom_api_key
        attendee_name:
          type: string
          description: >-
            The name of the attendee
            [cal.com](https://cal.com/docs/api-reference/v2/bookings/create-a-booking#body-attendee-name).
            If not provided, the assistant will ask for the attendee's name.
        attendee_timezone:
          type: string
          description: >-
            The timezone of the attendee
            [cal.com](https://cal.com/docs/api-reference/v2/bookings/create-a-booking#body-attendee-timezone).
            If not provided, the assistant will ask for the attendee's timezone.
      type: object
      required:
        - event_type_id
        - api_key_ref
      title: BookAppointmentToolParams
    CheckAvailabilityToolParams:
      properties:
        event_type_id:
          type: integer
          description: >-
            Event Type ID for which slots are being fetched.
            [cal.com](https://cal.com/docs/api-reference/v2/slots/get-available-slots#parameter-event-type-id)
        api_key_ref:
          type: string
          description: >-
            Reference to an integration secret that contains your Cal.com API
            key. You would pass the `identifier` for an integration secret
            [/v2/integration_secrets](https://developers.telnyx.com/api/secrets-manager/integration-secrets/create-integration-secret)
            that refers to your Cal.com API key.
          example: my_calcom_api_key
      type: object
      required:
        - event_type_id
        - api_key_ref
      title: CheckAvailabilityToolParams
    CallControlWebhookToolParams:
      properties:
        name:
          type: string
          description: The name of the tool.
        description:
          type: string
          description: The description of the tool.
        url:
          description: >-
            The URL of the external tool to be called. This URL is going to be
            used by the assistant. The URL can be templated like:
            `https://example.com/api/v1/{id}`, where `{id}` is a placeholder for
            a value that will be provided by the assistant if `path_parameters`
            are provided with the `id` attribute.
          type: string
          example: https://example.com/api/v1/function
        method:
          description: The HTTP method to be used when calling the external tool.
          type: string
          enum:
            - GET
            - POST
            - PUT
            - DELETE
            - PATCH
          default: POST
        headers:
          description: The headers to be sent to the external tool.
          type: array
          items:
            type: object
            properties:
              name:
                type: string
              value:
                description: >-
                  The value of the header. Note that we support mustache
                  templating for the value. For example you can use `Bearer
                  {{#integration_secret}}test-secret{{/integration_secret}}` to
                  pass the value of the integration secret as the bearer token.
                type: string
        body_parameters:
          description: >-
            The body parameters the webhook tool accepts, described as a JSON
            Schema object. These parameters will be passed to the webhook as the
            body of the request. See the [JSON Schema
            reference](https://json-schema.org/understanding-json-schema) for
            documentation about the format
          type: object
          properties:
            properties:
              description: The properties of the body parameters.
              type: object
            required:
              description: The required properties of the body parameters.
              type: array
              items:
                type: string
            type:
              type: string
              enum:
                - object
          example:
            properties:
              age:
                description: The age of the customer.
                type: integer
              location:
                description: The location of the customer.
                type: string
            required:
              - age
              - location
            type: object
        path_parameters:
          description: >-
            The path parameters the webhook tool accepts, described as a JSON
            Schema object. These parameters will be passed to the webhook as the
            path of the request if the URL contains a placeholder for a value.
            See the [JSON Schema
            reference](https://json-schema.org/understanding-json-schema) for
            documentation about the format
          type: object
          properties:
            properties:
              description: The properties of the path parameters.
              type: object
            required:
              description: The required properties of the path parameters.
              type: array
              items:
                type: string
            type:
              type: string
              enum:
                - object
          example:
            properties:
              id:
                description: The id of the customer.
                type: string
            required:
              - id
            type: object
        query_parameters:
          description: >-
            The query parameters the webhook tool accepts, described as a JSON
            Schema object. These parameters will be passed to the webhook as the
            query of the request. See the [JSON Schema
            reference](https://json-schema.org/understanding-json-schema) for
            documentation about the format
          type: object
          properties:
            properties:
              description: The properties of the query parameters.
              type: object
            required:
              description: The required properties of the query parameters.
              type: array
              items:
                type: string
            type:
              type: string
              enum:
                - object
          example:
            properties:
              page:
                description: The page number.
                type: integer
            required:
              - page
            type: object
      type: object
      required:
        - url
        - name
        - description
      title: WebhookToolParams
    HangupToolParams:
      properties:
        description:
          type: string
          default: This tool is used to hang up the call.
          description: >-
            The description of the function that will be passed to the
            assistant.
      type: object
      title: HangupToolParams
    CallControlTransferToolParams:
      properties:
        targets:
          oneOf:
            - type: array
              items:
                type: object
                properties:
                  name:
                    type: string
                    description: The name of the target.
                    example: Support
                  to:
                    type: string
                    description: The destination number or SIP URI of the call.
                    example: '+13129457420'
                required:
                  - to
            - type: string
              description: >-
                A dynamic variable string like `{{ targets }}` where `targets`
                is returned by the dynamic variables webhook and resolves to an
                array of target objects at runtime.
              example: '{{ targets }}'
          description: >-
            The different possible targets of the transfer. The assistant will
            be able to choose one of the targets to transfer the call to. This
            can also be a dynamic variable string like `{{ targets }}` where
            `targets` is returned by the dynamic variables webhook and resolves
            to an array of target objects at runtime.
        from:
          type: string
          example: '+35319605860'
          description: Number or SIP URI placing the call.
      type: object
      required:
        - targets
        - from
      title: TransferToolParams
    CallControlBucketIds:
      properties:
        bucket_ids:
          items:
            type: string
          type: array
          title: Bucket Ids
        max_num_results:
          description: >-
            The maximum number of results to retrieve as context for the
            language model.
          type: integer
      type: object
      required:
        - bucket_ids
      title: BucketIds
    ResembleSampleRate:
      type: string
      title: Resemble Sample Rate
      description: Audio sample rate in Hz.
      enum:
        - '8000'
        - '16000'
        - '22050'
        - '32000'
        - '44100'
        - '48000'
      default: '48000'
    GoogleTranscriptionLanguage:
      title: Google transcription engine list of languages
      type: string
      description: Language to use for speech recognition
      example: en
      default: en
      enum:
        - af
        - sq
        - am
        - ar
        - hy
        - az
        - eu
        - bn
        - bs
        - bg
        - my
        - ca
        - yue
        - zh
        - hr
        - cs
        - da
        - nl
        - en
        - et
        - fil
        - fi
        - fr
        - gl
        - ka
        - de
        - el
        - gu
        - iw
        - hi
        - hu
        - is
        - id
        - it
        - ja
        - jv
        - kn
        - kk
        - km
        - ko
        - lo
        - lv
        - lt
        - mk
        - ms
        - ml
        - mr
        - mn
        - ne
        - 'no'
        - fa
        - pl
        - pt
        - pa
        - ro
        - ru
        - rw
        - sr
        - si
        - sk
        - sl
        - ss
        - st
        - es
        - su
        - sw
        - sv
        - ta
        - te
        - th
        - tn
        - tr
        - ts
        - uk
        - ur
        - uz
        - ve
        - vi
        - xh
        - zu
    TelnyxTranscriptionLanguage:
      title: Telnyx transcription engine list of languages
      type: string
      description: Language to use for speech recognition
      example: en
      default: en
      enum:
        - en
        - zh
        - de
        - es
        - ru
        - ko
        - fr
        - ja
        - pt
        - tr
        - pl
        - ca
        - nl
        - ar
        - sv
        - it
        - id
        - hi
        - fi
        - vi
        - he
        - uk
        - el
        - ms
        - cs
        - ro
        - da
        - hu
        - ta
        - 'no'
        - th
        - ur
        - hr
        - bg
        - lt
        - la
        - mi
        - ml
        - cy
        - sk
        - te
        - fa
        - lv
        - bn
        - sr
        - az
        - sl
        - kn
        - et
        - mk
        - br
        - eu
        - is
        - hy
        - ne
        - mn
        - bs
        - kk
        - sq
        - sw
        - gl
        - mr
        - pa
        - si
        - km
        - sn
        - yo
        - so
        - af
        - oc
        - ka
        - be
        - tg
        - sd
        - gu
        - am
        - yi
        - lo
        - uz
        - fo
        - ht
        - ps
        - tk
        - nn
        - mt
        - sa
        - lb
        - my
        - bo
        - tl
        - mg
        - as
        - tt
        - haw
        - ln
        - ha
        - ba
        - jw
        - su
        - auto_detect
    DeepgramNova2Config:
      type: object
      title: DeepgramNova2Config
      properties:
        transcription_engine:
          type: string
          enum:
            - Deepgram
        transcription_model:
          type: string
          enum:
            - deepgram/nova-2
        interim_results:
          type: boolean
          description: >-
            Whether to send also interim results. If set to false, only final
            results will be sent.
          default: false
          example: true
        utterance_end_ms:
          type: integer
          default: 1000
          example: 800
          minimum: 0
          maximum: 5000
          description: >-
            Number of milliseconds of silence to consider an utterance ended.
            Ranges from 0 to 5000 ms.
        language:
          $ref: '#/components/schemas/DeepgramNova2TranscriptionLanguage'
        smart_format:
          type: boolean
          default: true
          example: false
          description: >-
            Enable Deepgram's smart formatting (capitalization, punctuation, and
            digit normalization). Note: Telnyx defaults this to `true`,
            overriding Deepgram's underlying default of `false` — omit the field
            to get a smart-formatted transcript, or set it to `false` to receive
            the raw lowercase transcript without punctuation.
        keywords_boosting:
          type: object
          description: >-
            Keywords and their respective intensifiers (boosting values) to
            improve transcription accuracy for specific words or phrases. The
            intensifier should be a numeric value. Example: `{"snuffleupagus":
            5, "systrom": 2, "krieger": 1}`.
          additionalProperties:
            type: number
            description: >-
              Boost intensifier for the keyword. Higher values increase
              recognition confidence.
          default: null
          example:
            snuffleupagus: 5
            systrom: 2
            krieger: 1
        hints:
          type: array
          description: >-
            Nova-2 keyword biasing without intensifiers. Up to 100 terms to bias
            recognition toward. For weighted biasing, use `keywords_boosting`
            instead. Nova-2-only; use `keyterms` on Nova-3.
          items:
            type: string
          maxItems: 100
          default: []
          example:
            - Telnyx
            - LiveKit
            - VoIP
      additionalProperties: false
      required:
        - transcription_engine
        - transcription_model
      example:
        transcription_engine: Deepgram
        transcription_model: deepgram/nova-2
        language: en
        smart_format: false
        hints:
          - Telnyx
          - LiveKit
          - VoIP
        keywords_boosting:
          snuffleupagus: 5
          systrom: 2
          krieger: 1
    DeepgramNova3Config:
      type: object
      title: DeepgramNova3Config
      properties:
        transcription_engine:
          type: string
          enum:
            - Deepgram
        transcription_model:
          type: string
          enum:
            - deepgram/nova-3
        interim_results:
          type: boolean
          description: >-
            Whether to send also interim results. If set to false, only final
            results will be sent.
          default: false
          example: true
        utterance_end_ms:
          type: integer
          default: 1000
          example: 800
          minimum: 0
          maximum: 5000
          description: >-
            Number of milliseconds of silence to consider an utterance ended.
            Ranges from 0 to 5000 ms.
        language:
          $ref: '#/components/schemas/DeepgramNova3TranscriptionLanguage'
        smart_format:
          type: boolean
          default: true
          example: false
          description: >-
            Enable Deepgram's smart formatting (capitalization, punctuation, and
            digit normalization). Note: Telnyx defaults this to `true`,
            overriding Deepgram's underlying default of `false` — omit the field
            to get a smart-formatted transcript, or set it to `false` to receive
            the raw lowercase transcript without punctuation.
        keywords_boosting:
          type: object
          description: >-
            Keywords and their respective intensifiers (boosting values) to
            improve transcription accuracy for specific words or phrases. The
            intensifier should be a numeric value. Example: `{"snuffleupagus":
            5, "systrom": 2, "krieger": 1}`.
          additionalProperties:
            type: number
            description: >-
              Boost intensifier for the keyword. Higher values increase
              recognition confidence.
          default: null
          example:
            snuffleupagus: 5
            systrom: 2
            krieger: 1
        keyterms:
          type: array
          description: >-
            Nova-3 keyterm prompting. Up to 100 domain-specific terms or brand
            names to bias recognition toward. Nova-3-only; use `hints` on
            Nova-2.
          items:
            type: string
          maxItems: 100
          default: []
          example:
            - Telnyx
            - LiveKit
            - VoIP
      additionalProperties: false
      required:
        - transcription_engine
        - transcription_model
      example:
        transcription_engine: Deepgram
        transcription_model: deepgram/nova-3
        language: en
        smart_format: false
        keyterms:
          - Telnyx
          - LiveKit
          - VoIP
        keywords_boosting:
          snuffleupagus: 5
          systrom: 2
          krieger: 1
    AzureTranscriptionLanguage:
      title: Azure transcription engine list of languages
      type: string
      description: Language to use for speech recognition
      example: en
      default: en
      enum:
        - af
        - am
        - ar
        - bg
        - bn
        - bs
        - ca
        - cs
        - cy
        - da
        - de
        - el
        - en
        - es
        - et
        - eu
        - fa
        - fi
        - fr
        - ga
        - gl
        - gu
        - he
        - hi
        - hr
        - hu
        - hy
        - id
        - is
        - it
        - ja
        - ka
        - kk
        - km
        - kn
        - ko
        - lo
        - lt
        - lv
        - mk
        - ml
        - mn
        - mr
        - ms
        - mt
        - my
        - nb
        - ne
        - nl
        - pl
        - ps
        - pt
        - ro
        - ru
        - si
        - sk
        - sl
        - so
        - sq
        - sr
        - sv
        - sw
        - ta
        - te
        - th
        - tr
        - uk
        - ur
        - uz
        - vi
        - wuu
        - yue
        - zh
        - zu
        - auto
    AzureTranscriptionRegion:
      title: Azure transcription engine list of regions
      type: string
      description: Azure region to use for speech recognition
      example: eastus
      enum:
        - australiaeast
        - centralindia
        - eastus
        - northcentralus
        - westeurope
        - westus2
    XaiTranscriptionLanguage:
      title: xAI transcription engine list of languages
      type: string
      description: Language to use for speech recognition
      example: en
      default: en
      enum:
        - ar
        - cs
        - da
        - de
        - en
        - es
        - fa
        - fil
        - fr
        - hi
        - id
        - it
        - ja
        - ko
        - mk
        - ms
        - nl
        - pl
        - pt
        - ro
        - ru
        - sv
        - th
        - tr
        - vi
    SpeechmaticsTranscriptionLanguage:
      title: Speechmatics transcription engine list of languages
      type: string
      description: Language to use for speech recognition
      example: en
      default: en
      enum:
        - en
        - ba
        - eu
        - gl
        - ga
        - mt
        - mn
        - sw
        - ug
        - cy
        - ar_en
        - cmn_en
        - en_ms
        - en_ta
        - tl
        - es-bilingual-en
        - cmn_en_ms_ta
    DeepgramNova2TranscriptionLanguage:
      title: Deepgram nova-2 transcription engine list of languages
      type: string
      description: Language to use for speech recognition with nova-2 model
      example: en
      default: en
      enum:
        - bg
        - ca
        - zh
        - zh-CN
        - zh-Hans
        - zh-TW
        - zh-Hant
        - zh-HK
        - cs
        - da
        - da-DK
        - nl
        - en
        - en-US
        - en-AU
        - en-GB
        - en-NZ
        - en-IN
        - et
        - fi
        - nl-BE
        - fr
        - fr-CA
        - de
        - de-CH
        - el
        - hi
        - hu
        - id
        - it
        - ja
        - ko
        - ko-KR
        - lv
        - lt
        - ms
        - 'no'
        - pl
        - pt
        - pt-BR
        - pt-PT
        - ro
        - ru
        - sk
        - es
        - es-419
        - sv
        - sv-SE
        - th
        - th-TH
        - tr
        - uk
        - vi
        - auto_detect
    DeepgramNova3TranscriptionLanguage:
      title: Deepgram nova-3 transcription engine list of languages
      type: string
      description: Language to use for speech recognition with nova-3 model
      example: en
      default: en
      enum:
        - en
        - en-US
        - en-AU
        - en-GB
        - en-IN
        - en-NZ
        - de
        - nl
        - sv
        - sv-SE
        - da
        - da-DK
        - es
        - es-419
        - fr
        - fr-CA
        - pt
        - pt-BR
        - pt-PT
        - auto_detect
  responses:
    BadRequestResponse:
      description: >-
        Bad request. The request was invalid or cannot be served. Common causes
        include: audio file download failures, attempting to delete non-empty
        queues, invalid characters in the request, or character encoding errors.
      content:
        application/json:
          schema:
            $ref: '#/components/schemas/Errors'
          examples:
            audio_file_download_failed:
              summary: Audio file download failed
              value:
                errors:
                  - code: '90040'
                    title: Downloading audio file failed
                    detail: Provided audio file couldn't be downloaded.
            queue_not_empty:
              summary: Queue not empty
              value:
                errors:
                  - code: '90050'
                    title: Unable to delete queue
                    detail: Only empty queues can be deleted.
            invalid_characters:
              summary: Invalid characters
              value:
                errors:
                  - code: '10015'
                    title: Bad Request
                    detail: Invalid characters in the request.
            character_encoding_error:
              summary: Character encoding error
              value:
                errors:
                  - code: '10028'
                    title: Character encoding error
                    detail: Error decoding request body at position 42
                    meta:
                      url: https://developers.telnyx.com/docs/overview/errors/10028
    UnprocessableEntityResponse:
      description: >-
        Unprocessable entity. The request was well-formed but could not be
        processed due to semantic errors. This includes validation errors,
        invalid parameter values, call state errors, conference errors, queue
        errors, recording/transcription errors, and business logic violations.
      content:
        application/json:
          schema:
            $ref: '#/components/schemas/Errors'
          examples:
            missing_required_parameter:
              summary: Missing required parameter
              value:
                errors:
                  - code: '10004'
                    title: Missing required parameter
                    detail: The 'to' parameter is required and cannot be blank.
                    source:
                      pointer: /to
            invalid_call_control_id:
              summary: Invalid call control ID
              value:
                errors:
                  - code: '90015'
                    title: Invalid Call Control ID
                    detail: The call_control_id provided was not valid.
                    source:
                      pointer: /call_control_id
            call_already_ended:
              summary: Call has already ended
              value:
                errors:
                  - code: '90018'
                    title: Call has already ended
                    detail: This call is no longer active and can't receive commands.
            call_not_answered:
              summary: Call not answered yet
              value:
                errors:
                  - code: '90034'
                    title: Call not answered yet
                    detail: >-
                      This call can't receive this command because it has not
                      been answered yet.
            cannot_record_before_audio_started:
              summary: Cannot record before audio started
              value:
                errors:
                  - code: '90020'
                    title: Call recording triggered before audio started
                    detail: >-
                      Call recording cannot be started until audio has commenced
                      on the call.
            transcription_already_active:
              summary: Transcription already active
              value:
                errors:
                  - code: '90054'
                    title: Call transcription is already in progress
                    detail: Call transcription can not be started more than once.
            ai_assistant_already_active:
              summary: AI Assistant already active
              value:
                errors:
                  - code: '90061'
                    title: AI Assistant is already in progress
                    detail: AI Assistant cannot be started more than once.
            conference_already_ended:
              summary: Conference has already ended
              value:
                errors:
                  - code: '90019'
                    title: Conference has already ended
                    detail: >-
                      This conference is no longer active and can't receive
                      commands.
            conference_name_conflict:
              summary: Conference name conflict
              value:
                errors:
                  - code: '90033'
                    title: Unable to execute command
                    detail: Conference with given name already exists and it's active.
            max_participants_reached:
              summary: Maximum participants reached
              value:
                errors:
                  - code: '90032'
                    title: Maximum number of participants reached
                    detail: >-
                      The maximum allowed value of `max_participants` has been
                      reached at 100.
            queue_full:
              summary: Queue is full
              value:
                errors:
                  - code: '90036'
                    title: Queue full
                    detail: The 'support' queue is full and can't accept more calls.
            call_already_in_queue:
              summary: Call already in queue
              value:
                errors:
                  - code: '90038'
                    title: Call already in queue
                    detail: Call can't be added to a queue it's already in.
            invalid_connection_id:
              summary: Invalid connection ID
              value:
                errors:
                  - code: '10015'
                    title: Invalid value for connection_id (Call Control App ID)
                    detail: >-
                      The requested connection_id (Call Control App ID) is
                      either invalid or does not exist. Only Call Control Apps
                      with valid webhook URL are accepted.
                    source:
                      pointer: /connection_id
            invalid_phone_number_format:
              summary: Invalid phone number format
              value:
                errors:
                  - code: '10016'
                    title: Phone number must be in +E164 format
                    detail: The 'to' parameter must be in E164 format.
                    source:
                      pointer: /to
            srtp_not_supported_for_pstn:
              summary: SRTP not supported for PSTN calls
              value:
                errors:
                  - source:
                      pointer: /media_encryption
                    title: Media encryption not supported for PSTN calls
                    detail: SRTP media encryption is not supported for PSTN calls.
                    code: '10011'
            fork_not_found:
              summary: Call is not forked
              value:
                errors:
                  - code: '90031'
                    title: Call is not currently forked
                    detail: >-
                      Can't stop forking, because the call isn't currently
                      forked.
            media_streaming_used:
              summary: Media streaming in use
              value:
                errors:
                  - code: '90045'
                    title: Media Streaming is used
                    detail: This command can't be issued when media streaming is used.
            invalid_enumerated_value:
              summary: Invalid enumerated value
              value:
                errors:
                  - code: '10032'
                    title: Invalid enumerated value
                    detail: 'The value must be one of: dual, single.'
                    source:
                      pointer: /record_channels
            value_outside_range:
              summary: Value outside of range
              value:
                errors:
                  - code: '10033'
                    title: Value outside of range
                    detail: The value is outside of allowed range 1 to 5000
                    source:
                      pointer: /max_participants
    InternalServerErrorResponse:
      description: >-
        Internal server error. An unexpected error occurred on the server. This
        is typically returned for unhandled exceptions or system failures.
      content:
        application/json:
          schema:
            $ref: '#/components/schemas/Errors'
          example:
            errors:
              - code: '10007'
                title: Internal server error
                detail: Internal server error
    ServiceUnavailableResponse:
      description: >-
        Service unavailable. The service is temporarily unavailable. This may
        occur during maintenance or when the service is overloaded.
      content:
        application/json:
          schema:
            $ref: '#/components/schemas/Errors'
          example:
            errors:
              - code: '10007'
                title: Service unavailable
                detail: Service unavailable
    GenericErrorResponse:
      description: Unexpected error
      content:
        application/json:
          schema:
            $ref: '#/components/schemas/Errors'
          example:
            errors:
              - code: '10007'
                title: Unexpected error
                detail: An unexpected error occured.
  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer

````
