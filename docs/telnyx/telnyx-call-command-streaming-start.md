> ## Documentation Index
> Fetch the complete documentation index at: https://developers.telnyx.com/llms.txt
> Use this file to discover all available pages before exploring further.

# Streaming start

> Start streaming the media from a call to a specific WebSocket address or Dialogflow connection in near-realtime. Audio will be delivered as base64-encoded RTP payload (raw audio), wrapped in JSON payloads.

Please find more details about media streaming messages specification under the [link](https://developers.telnyx.com/docs/voice/programmable-voice/media-streaming).



## OpenAPI

````yaml /openapi/source/external/call-control/call-control.json post /calls/{call_control_id}/actions/streaming_start
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
  /calls/{call_control_id}/actions/streaming_start:
    post:
      tags:
        - Call Commands
      summary: Streaming start
      description: >-
        Start streaming the media from a call to a specific WebSocket address or
        Dialogflow connection in near-realtime. Audio will be delivered as
        base64-encoded RTP payload (raw audio), wrapped in JSON payloads.


        Please find more details about media streaming messages specification
        under the
        [link](https://developers.telnyx.com/docs/voice/programmable-voice/media-streaming).
      operationId: StartCallStreaming
      parameters:
        - $ref: '#/components/parameters/CallControlId'
      requestBody:
        description: Start streaming media request
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/StartStreamingRequest'
      responses:
        '200':
          description: Successful response upon making a call control command.
          content:
            application/json:
              schema:
                type: object
                title: Call Control Command Response
                properties:
                  data:
                    $ref: '#/components/schemas/CallControlCommandResult'
        '422':
          $ref: '#/components/responses/UnprocessableEntityResponse'
        default:
          $ref: '#/components/responses/GenericErrorResponse'
      x-codeSamples:
        - lang: JavaScript
          source: >-
            import Telnyx from 'telnyx';


            const client = new Telnyx({
              apiKey: process.env['TELNYX_API_KEY'], // This is the default and can be omitted
            });


            const response = await
            client.calls.actions.startStreaming('call_control_id');


            console.log(response.data);
        - lang: Python
          source: |
            import os
            from telnyx import Telnyx

            client = Telnyx(
                api_key=os.environ.get("TELNYX_API_KEY"),  # This is the default and can be omitted
            )
            response = client.calls.actions.start_streaming(
                call_control_id="call_control_id",
            )
            print(response.data)
        - lang: Go
          source: "package main\n\nimport (\n\t\"context\"\n\t\"fmt\"\n\n\t\"github.com/team-telnyx/telnyx-go\"\n\t\"github.com/team-telnyx/telnyx-go/option\"\n)\n\nfunc main() {\n\tclient := telnyx.NewClient(\n\t\toption.WithAPIKey(\"My API Key\"),\n\t)\n\tresponse, err := client.Calls.Actions.StartStreaming(\n\t\tcontext.TODO(),\n\t\t\"call_control_id\",\n\t\ttelnyx.CallActionStartStreamingParams{},\n\t)\n\tif err != nil {\n\t\tpanic(err.Error())\n\t}\n\tfmt.Printf(\"%+v\\n\", response.Data)\n}\n"
        - lang: Java
          source: >-
            package com.telnyx.sdk.example;


            import com.telnyx.sdk.client.TelnyxClient;

            import com.telnyx.sdk.client.okhttp.TelnyxOkHttpClient;

            import
            com.telnyx.sdk.models.calls.actions.ActionStartStreamingParams;

            import
            com.telnyx.sdk.models.calls.actions.ActionStartStreamingResponse;


            public final class Main {
                private Main() {}

                public static void main(String[] args) {
                    TelnyxClient client = TelnyxOkHttpClient.fromEnv();

                    ActionStartStreamingResponse response = client.calls().actions().startStreaming("call_control_id");
                }
            }
        - lang: Ruby
          source: |-
            require "telnyx"

            telnyx = Telnyx::Client.new(api_key: "My API Key")

            response = telnyx.calls.actions.start_streaming("call_control_id")

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

            use Telnyx\Core\Exceptions\APIException;


            $client = new Client(apiKey: getenv('TELNYX_API_KEY') ?: 'My API
            Key');


            try {
              $response = $client->calls->actions->startStreaming(
                'call_control_id',
                clientState: 'aGF2ZSBhIG5pY2UgZGF5ID1d',
                commandID: '891510ac-f3e4-11e8-af5b-de00688a4901',
                customParameters: [
                  ['name' => 'param1', 'value' => 'value1'],
                  ['name' => 'param2', 'value' => 'value2'],
                ],
                dialogflowConfig: [
                  'analyzeSentiment' => false, 'partialAutomatedAgentReply' => false
                ],
                enableDialogflow: false,
                streamAuthToken: 'your-auth-token',
                streamBidirectionalCodec: StreamBidirectionalCodec::G722,
                streamBidirectionalMode: StreamBidirectionalMode::RTP,
                streamBidirectionalSamplingRate: StreamBidirectionalSamplingRate::RATE_16000,
                streamBidirectionalTargetLegs: StreamBidirectionalTargetLegs::BOTH,
                streamCodec: StreamCodec::PCMA,
                streamTrack: 'both_tracks',
                streamURL: 'wss://www.example.com/websocket',
              );

              var_dump($response);
            } catch (APIException $e) {
              echo $e->getMessage();
            }
        - lang: CLI
          source: |-
            telnyx calls:actions start-streaming \
              --api-key 'My API Key' \
              --call-control-id call_control_id
components:
  parameters:
    CallControlId:
      name: call_control_id
      description: Unique identifier and token for controlling the call
      in: path
      required: true
      schema:
        type: string
  schemas:
    StartStreamingRequest:
      type: object
      title: Start Streaming Request
      properties:
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
        enable_dialogflow:
          description: Enables Dialogflow for the current call. The default value is false.
          type: boolean
          default: false
          example: true
        dialogflow_config:
          $ref: '#/components/schemas/DialogflowConfig'
        client_state:
          description: >-
            Use this field to add state to every subsequent webhook. It must be
            a valid Base-64 encoded string.
          type: string
          example: aGF2ZSBhIG5pY2UgZGF5ID1d
        command_id:
          description: >-
            Use this field to avoid duplicate commands. Telnyx will ignore any
            command with the same `command_id` for the same `call_control_id`.
          type: string
          example: 891510ac-f3e4-11e8-af5b-de00688a4901
        custom_parameters:
          description: Custom parameters to be sent as part of the WebSocket connection.
          type: array
          items:
            type: object
            properties:
              name:
                type: string
                description: The name of the custom parameter.
              value:
                type: string
                description: The value of the custom parameter.
          example:
            - name: param1
              value: value1
            - name: param2
              value: value2
        stream_auth_token:
          description: >-
            An authentication token to be sent as part of the WebSocket
            connection. Maximum length is 4000 characters.
          type: string
          maxLength: 4000
          example: your-auth-token
      example:
        stream_url: wss://www.example.com/websocket
        stream_track: both_tracks
        client_state: aGF2ZSBhIG5pY2UgZGF5ID1d
        command_id: 891510ac-f3e4-11e8-af5b-de00688a4901
        enable_dialogflow: false
        dialogflow_config:
          analyze_sentiment: false
          partial_automated_agent_reply: false
    CallControlCommandResult:
      type: object
      title: Call Control Command Result
      example:
        result: ok
      properties:
        result:
          type: string
          example: ok
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
    Errors:
      properties:
        errors:
          type: array
          items:
            $ref: '#/components/schemas/Error'
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
  responses:
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
