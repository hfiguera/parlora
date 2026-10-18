> ## Documentation Index
> Fetch the complete documentation index at: https://developers.telnyx.com/llms.txt
> Use this file to discover all available pages before exploring further.

# Start streaming media from a call.

> Starts streaming media from a call to a specific WebSocket address.



## OpenAPI

````yaml /openapi/source/external/call-scripting/call-scripting.json post /texml/Accounts/{account_sid}/Calls/{call_sid}/Streams.json
openapi: 3.1.0
info:
  version: 2.0.0
  title: Telnyx API
  x-latency-category: interactive
  x-endpoint-cost: light
  description: SIP trunking, SMS, MMS, Call Control and Telephony Data Services.
  license:
    name: MIT
    url: https://opensource.org/licenses/MIT
  contact:
    email: support@telnyx.com
  x-responsible-team: squad-telephony-apps
servers:
  - url: https://api.telnyx.com/v2
    description: Version 2.0.0 of the Telnyx API
security:
  - bearerAuth: []
tags:
  - name: TeXML REST Commands
    description: TeXML REST Commands
  - name: TeXML Applications
    description: TeXML Applications operations
paths:
  /texml/Accounts/{account_sid}/Calls/{call_sid}/Streams.json:
    post:
      tags:
        - TeXML REST Commands
      summary: Start streaming media from a call.
      description: Starts streaming media from a call to a specific WebSocket address.
      operationId: StartTeXMLCallStreaming
      parameters:
        - $ref: '#/components/parameters/AccountSid'
        - $ref: '#/components/parameters/CallSid'
      requestBody:
        $ref: '#/components/requestBodies/TexmlCreateCallStreamingRequest'
      responses:
        '200':
          description: Successful call streaming create response
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/TexmlCreateCallStreamingResponseBody'
        '404':
          $ref: '#/components/responses/NotFoundResponse'
      x-codeSamples:
        - lang: JavaScript
          source: >-
            import Telnyx from 'telnyx';


            const client = new Telnyx({
              apiKey: process.env['TELNYX_API_KEY'], // This is the default and can be omitted
            });


            const response = await
            client.texml.accounts.calls.streamsJson('call_sid', {
              account_sid: 'account_sid',
            });


            console.log(response.account_sid);
        - lang: Python
          source: |
            import os
            from telnyx import Telnyx

            client = Telnyx(
                api_key=os.environ.get("TELNYX_API_KEY"),  # This is the default and can be omitted
            )
            response = client.texml.accounts.calls.streams_json(
                call_sid="call_sid",
                account_sid="account_sid",
            )
            print(response.account_sid)
        - lang: Go
          source: "package main\n\nimport (\n\t\"context\"\n\t\"fmt\"\n\n\t\"github.com/team-telnyx/telnyx-go\"\n\t\"github.com/team-telnyx/telnyx-go/option\"\n)\n\nfunc main() {\n\tclient := telnyx.NewClient(\n\t\toption.WithAPIKey(\"My API Key\"),\n\t)\n\tresponse, err := client.Texml.Accounts.Calls.StreamsJson(\n\t\tcontext.TODO(),\n\t\t\"call_sid\",\n\t\ttelnyx.TexmlAccountCallStreamsJsonParams{\n\t\t\tAccountSid: \"account_sid\",\n\t\t},\n\t)\n\tif err != nil {\n\t\tpanic(err.Error())\n\t}\n\tfmt.Printf(\"%+v\\n\", response.AccountSid)\n}\n"
        - lang: Java
          source: >-
            package com.telnyx.sdk.example;


            import com.telnyx.sdk.client.TelnyxClient;

            import com.telnyx.sdk.client.okhttp.TelnyxOkHttpClient;

            import
            com.telnyx.sdk.models.texml.accounts.calls.CallStreamsJsonParams;

            import
            com.telnyx.sdk.models.texml.accounts.calls.CallStreamsJsonResponse;


            public final class Main {
                private Main() {}

                public static void main(String[] args) {
                    TelnyxClient client = TelnyxOkHttpClient.fromEnv();

                    CallStreamsJsonParams params = CallStreamsJsonParams.builder()
                        .accountSid("account_sid")
                        .callSid("call_sid")
                        .build();
                    CallStreamsJsonResponse response = client.texml().accounts().calls().streamsJson(params);
                }
            }
        - lang: Ruby
          source: >-
            require "telnyx"


            telnyx = Telnyx::Client.new(api_key: "My API Key")


            response = telnyx.texml.accounts.calls.streams_json("call_sid",
            account_sid: "account_sid")


            puts(response)
        - lang: PHP
          source: >-
            <?php


            require_once dirname(__DIR__) . '/vendor/autoload.php';


            use Telnyx\Client;

            use Telnyx\Core\Exceptions\APIException;


            $client = new Client(apiKey: getenv('TELNYX_API_KEY') ?: 'My API
            Key');


            try {
              $response = $client->texml->accounts->calls->streamsJson(
                'call_sid',
                accountSid: 'account_sid',
                bidirectionalCodec: 'G722',
                bidirectionalMode: 'rtp',
                name: 'My stream',
                statusCallback: 'http://webhook.com/callback',
                statusCallbackMethod: 'GET',
                track: 'both_tracks',
                url: 'wss://www.example.com/websocket',
              );

              var_dump($response);
            } catch (APIException $e) {
              echo $e->getMessage();
            }
        - lang: CLI
          source: |-
            telnyx texml:accounts:calls streams-json \
              --api-key 'My API Key' \
              --account-sid account_sid \
              --call-sid call_sid
components:
  parameters:
    AccountSid:
      name: account_sid
      in: path
      required: true
      description: The id of the account the resource belongs to.
      schema:
        type: string
    CallSid:
      name: call_sid
      in: path
      required: true
      description: The CallSid that identifies the call to update.
      schema:
        type: string
  requestBodies:
    TexmlCreateCallStreamingRequest:
      content:
        application/x-www-form-urlencoded:
          schema:
            $ref: '#/components/schemas/TexmlCreateCallStreamingRequestBody'
      description: Start streaming media from a call
  schemas:
    TexmlCreateCallStreamingResponseBody:
      type: object
      title: Texml Create Call Streaming Response Body
      properties:
        account_sid:
          $ref: '#/components/schemas/AccountSid'
        call_sid:
          $ref: '#/components/schemas/CallControlId'
        sid:
          $ref: '#/components/schemas/TexmlSid'
        name:
          description: The user specified name of Stream.
          example: My stream
          type: string
        status:
          type: string
          description: The status of the streaming.
          enum:
            - in-progress
          example: in-progress
        date_updated:
          $ref: '#/components/schemas/DateTimeRFC2822'
        uri:
          type: string
          description: The relative URI for this streaming resource.
          example: >-
            /v2/texml/Accounts/61bf923e-5e4d-4595-a110-56190ea18a1b/Calls/v3:KBnLO0ZK3DhKM5s7bE9VluaSmKsOchKht_fUYvxcp8ysbmzCCtpkmA/Streams/b08f0fa1-a32c-4218-b3b5-9cf78941ccac.json
    TexmlCreateCallStreamingRequestBody:
      type: object
      title: Texml Create Call Streaming Request Body
      properties:
        StatusCallback:
          $ref: '#/components/schemas/TexmlStatusCallback'
        StatusCallbackMethod:
          $ref: '#/components/schemas/TexmlStatusCallbackMethod'
        Track:
          $ref: '#/components/schemas/StreamTrack'
        Name:
          $ref: '#/components/schemas/StreamName'
        BidirectionalMode:
          $ref: '#/components/schemas/TexmlBidirectionalStreamMode'
        BidirectionalCodec:
          $ref: '#/components/schemas/TexmlBidirectionalStreamCodec'
        Url:
          $ref: '#/components/schemas/TexmlStreamUrl'
    AccountSid:
      type: string
      example: 61bf923e-5e4d-4595-a110-56190ea18a1b
    CallControlId:
      type: string
      example: v3:KBnLO0ZK3DhKM5s7bE9VluaSmKsOchKht_fUYvxcp8ysbmzCCtpkmA
    TexmlSid:
      type: string
      description: Identifier of a resource.
      example: e9cea0be-7dbd-4b98-98b1-c0089d9d43b0
    DateTimeRFC2822:
      type: string
      format: date-time
      example: '2023-08-11T19:12:11Z'
    ResourceNotFoundError:
      type: object
      title: Resource not found
      example:
        errors:
          - detail: Resource not found
      properties:
        errors:
          type: array
          items:
            type: object
            properties:
              detail:
                type: string
    TexmlStatusCallback:
      description: Url where status callbacks will be sent.
      example: http://webhook.com/callback
      type: string
      format: uri
    TexmlStatusCallbackMethod:
      description: HTTP method used to send status callbacks.
      example: GET
      type: string
      default: POST
      enum:
        - GET
        - POST
    StreamTrack:
      description: Tracks to be included in the stream
      default: inbound_track
      example: both_tracks
      type: string
      enum:
        - inbound_track
        - outbound_track
        - both_tracks
    StreamName:
      description: The user specified name of Stream.
      example: My stream
      type: string
    TexmlBidirectionalStreamMode:
      type: string
      title: Stream Bidirectional Mode
      description: Configures method of bidirectional streaming (mp3, rtp).
      enum:
        - mp3
        - rtp
      default: mp3
      example: rtp
    TexmlBidirectionalStreamCodec:
      type: string
      title: Stream Bidirectional Codec
      description: >-
        Indicates codec for bidirectional streaming RTP payloads. Used only with
        stream_bidirectional_mode=rtp. Case sensitive.
      enum:
        - PCMU
        - PCMA
        - G722
      default: PCMU
      example: G722
    TexmlStreamUrl:
      type: string
      title: Stream destination URL
      description: >-
        The destination WebSocket address where the stream is going to be
        delivered.
      example: wss://www.example.com/websocket
  responses:
    NotFoundResponse:
      description: Resource not found
      content:
        application/json:
          schema:
            $ref: '#/components/schemas/ResourceNotFoundError'
  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer

````