> ## Documentation Index
> Fetch the complete documentation index at: https://developers.telnyx.com/llms.txt
> Use this file to discover all available pages before exploring further.

# Retrieve a call status

> Returns the status of a call (data is available 10 minutes after call ended).



## OpenAPI

````yaml /openapi/source/external/call-control/call-control.json get /calls/{call_control_id}
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
  /calls/{call_control_id}:
    get:
      tags:
        - Call Information
      summary: Retrieve a call status
      description: >-
        Returns the status of a call (data is available 10 minutes after call
        ended).
      operationId: RetrieveCallStatus
      parameters:
        - $ref: '#/components/parameters/CallControlId'
      responses:
        '200':
          description: Successful response with details about a call status.
          content:
            application/json:
              schema:
                type: object
                title: Retrieve Call Status Response
                properties:
                  data:
                    $ref: '#/components/schemas/Call'
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
            client.calls.retrieveStatus('call_control_id');


            console.log(response.data);
        - lang: Python
          source: |
            import os
            from telnyx import Telnyx

            client = Telnyx(
                api_key=os.environ.get("TELNYX_API_KEY"),  # This is the default and can be omitted
            )
            response = client.calls.retrieve_status(
                "call_control_id",
            )
            print(response.data)
        - lang: Go
          source: "package main\n\nimport (\n\t\"context\"\n\t\"fmt\"\n\n\t\"github.com/team-telnyx/telnyx-go\"\n\t\"github.com/team-telnyx/telnyx-go/option\"\n)\n\nfunc main() {\n\tclient := telnyx.NewClient(\n\t\toption.WithAPIKey(\"My API Key\"),\n\t)\n\tresponse, err := client.Calls.GetStatus(context.TODO(), \"call_control_id\")\n\tif err != nil {\n\t\tpanic(err.Error())\n\t}\n\tfmt.Printf(\"%+v\\n\", response.Data)\n}\n"
        - lang: Java
          source: |-
            package com.telnyx.sdk.example;

            import com.telnyx.sdk.client.TelnyxClient;
            import com.telnyx.sdk.client.okhttp.TelnyxOkHttpClient;
            import com.telnyx.sdk.models.calls.CallRetrieveStatusParams;
            import com.telnyx.sdk.models.calls.CallRetrieveStatusResponse;

            public final class Main {
                private Main() {}

                public static void main(String[] args) {
                    TelnyxClient client = TelnyxOkHttpClient.fromEnv();

                    CallRetrieveStatusResponse response = client.calls().retrieveStatus("call_control_id");
                }
            }
        - lang: Ruby
          source: |-
            require "telnyx"

            telnyx = Telnyx::Client.new(api_key: "My API Key")

            response = telnyx.calls.retrieve_status("call_control_id")

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
              $response = $client->calls->retrieveStatus('call_control_id');

              var_dump($response);
            } catch (APIException $e) {
              echo $e->getMessage();
            }
        - lang: CLI
          source: |-
            telnyx calls retrieve-status \
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
    Call:
      type: object
      title: Call
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
        start_time: '2019-01-23T18:10:02.574Z'
        end_time: '2019-01-23T18:11:52.574Z'
        record_type: call
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
