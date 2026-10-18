> ## Documentation Index
> Fetch the complete documentation index at: https://developers.telnyx.com/llms.txt
> Use this file to discover all available pages before exploring further.

# Update streaming on a call

> Updates streaming resource for particular call.



## OpenAPI

````yaml /openapi/source/external/call-scripting/call-scripting.json post /texml/Accounts/{account_sid}/Calls/{call_sid}/Streams/{streaming_sid}.json
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
  /texml/Accounts/{account_sid}/Calls/{call_sid}/Streams/{streaming_sid}.json:
    post:
      tags:
        - TeXML REST Commands
      summary: Update streaming on a call
      description: Updates streaming resource for particular call.
      operationId: UpdateTeXMLCallStreaming
      parameters:
        - $ref: '#/components/parameters/AccountSid'
        - $ref: '#/components/parameters/CallSid'
        - $ref: '#/components/parameters/StreamingSid'
      requestBody:
        $ref: '#/components/requestBodies/TexmlUpdateCallStreamingRequest'
      responses:
        '200':
          description: Successful call streaming update response
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/TexmlUpdateCallStreamingResponseBody'
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
            client.texml.accounts.calls.streams.streamingSidJson(
              '6a09cdc3-8948-47f0-aa62-74ac943d6c58',
              { account_sid: 'account_sid', call_sid: 'call_sid' },
            );


            console.log(response.account_sid);
        - lang: Python
          source: |
            import os
            from telnyx import Telnyx

            client = Telnyx(
                api_key=os.environ.get("TELNYX_API_KEY"),  # This is the default and can be omitted
            )
            response = client.texml.accounts.calls.streams.streaming_sid_json(
                streaming_sid="6a09cdc3-8948-47f0-aa62-74ac943d6c58",
                account_sid="account_sid",
                call_sid="call_sid",
            )
            print(response.account_sid)
        - lang: Go
          source: "package main\n\nimport (\n\t\"context\"\n\t\"fmt\"\n\n\t\"github.com/team-telnyx/telnyx-go\"\n\t\"github.com/team-telnyx/telnyx-go/option\"\n)\n\nfunc main() {\n\tclient := telnyx.NewClient(\n\t\toption.WithAPIKey(\"My API Key\"),\n\t)\n\tresponse, err := client.Texml.Accounts.Calls.Streams.StreamingSidJson(\n\t\tcontext.TODO(),\n\t\t\"6a09cdc3-8948-47f0-aa62-74ac943d6c58\",\n\t\ttelnyx.TexmlAccountCallStreamStreamingSidJsonParams{\n\t\t\tAccountSid: \"account_sid\",\n\t\t\tCallSid:    \"call_sid\",\n\t\t},\n\t)\n\tif err != nil {\n\t\tpanic(err.Error())\n\t}\n\tfmt.Printf(\"%+v\\n\", response.AccountSid)\n}\n"
        - lang: Java
          source: >-
            package com.telnyx.sdk.example;


            import com.telnyx.sdk.client.TelnyxClient;

            import com.telnyx.sdk.client.okhttp.TelnyxOkHttpClient;

            import
            com.telnyx.sdk.models.texml.accounts.calls.streams.StreamStreamingSidJsonParams;

            import
            com.telnyx.sdk.models.texml.accounts.calls.streams.StreamStreamingSidJsonResponse;


            public final class Main {
                private Main() {}

                public static void main(String[] args) {
                    TelnyxClient client = TelnyxOkHttpClient.fromEnv();

                    StreamStreamingSidJsonParams params = StreamStreamingSidJsonParams.builder()
                        .accountSid("account_sid")
                        .callSid("call_sid")
                        .streamingSid("6a09cdc3-8948-47f0-aa62-74ac943d6c58")
                        .build();
                    StreamStreamingSidJsonResponse response = client.texml().accounts().calls().streams().streamingSidJson(params);
                }
            }
        - lang: Ruby
          source: |-
            require "telnyx"

            telnyx = Telnyx::Client.new(api_key: "My API Key")

            response = telnyx.texml.accounts.calls.streams.streaming_sid_json(
              "6a09cdc3-8948-47f0-aa62-74ac943d6c58",
              account_sid: "account_sid",
              call_sid: "call_sid"
            )

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
              $response = $client->texml->accounts->calls->streams->streamingSidJson(
                '6a09cdc3-8948-47f0-aa62-74ac943d6c58',
                accountSid: 'account_sid',
                callSid: 'call_sid',
                status: 'stopped',
              );

              var_dump($response);
            } catch (APIException $e) {
              echo $e->getMessage();
            }
        - lang: CLI
          source: |-
            telnyx texml:accounts:calls:streams streaming-sid-json \
              --api-key 'My API Key' \
              --account-sid account_sid \
              --call-sid call_sid \
              --streaming-sid 6a09cdc3-8948-47f0-aa62-74ac943d6c58
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
    StreamingSid:
      description: Uniquely identifies the streaming by id.
      name: streaming_sid
      in: path
      required: true
      schema:
        format: uuid
        type: string
        example: 6a09cdc3-8948-47f0-aa62-74ac943d6c58
  requestBodies:
    TexmlUpdateCallStreamingRequest:
      content:
        application/x-www-form-urlencoded:
          schema:
            $ref: '#/components/schemas/TexmlUpdateCallStreamingRequestBody'
      description: Update streaming
  schemas:
    TexmlUpdateCallStreamingResponseBody:
      type: object
      title: Texml Update Call Streaming Response Body
      properties:
        account_sid:
          $ref: '#/components/schemas/AccountSid'
        call_sid:
          $ref: '#/components/schemas/CallControlId'
        sid:
          $ref: '#/components/schemas/TexmlSid'
        status:
          type: string
          description: The status of the streaming.
          enum:
            - stopped
          example: stopped
        date_updated:
          $ref: '#/components/schemas/DateTimeRFC2822'
        uri:
          type: string
          description: The relative URI for this streaming resource.
          example: >-
            /v2/texml/Accounts/61bf923e-5e4d-4595-a110-56190ea18a1b/Calls/v3:KBnLO0ZK3DhKM5s7bE9VluaSmKsOchKht_fUYvxcp8ysbmzCCtpkmA/Streams/b08f0fa1-a32c-4218-b3b5-9cf78941ccac.json
    TexmlUpdateCallStreamingRequestBody:
      type: object
      title: Texml Update Call Streaming Request Body
      properties:
        Status:
          $ref: '#/components/schemas/StreamStatus'
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
    StreamStatus:
      description: The status of the Stream you wish to update.
      default: stopped
      example: stopped
      type: string
      enum:
        - stopped
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