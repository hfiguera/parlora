> ## Documentation Index
> Fetch the complete documentation index at: https://developers.telnyx.com/llms.txt
> Use this file to discover all available pages before exploring further.

# List call events

> Filters call events by given filter parameters. Events are ordered by `occurred_at`. If filter for `leg_id` or `application_session_id` is not present, it only filters events from the last 24 hours.

**Note**: Only one `filter[occurred_at]` can be passed.




## OpenAPI

````yaml /openapi/source/external/call-control/call-control.json get /call_events
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
  /call_events:
    get:
      tags:
        - Debugging
      summary: List call events
      description: >
        Filters call events by given filter parameters. Events are ordered by
        `occurred_at`. If filter for `leg_id` or `application_session_id` is not
        present, it only filters events from the last 24 hours.


        **Note**: Only one `filter[occurred_at]` can be passed.
      operationId: ListCallEvents
      parameters:
        - $ref: '#/components/parameters/FilterConsolidated'
        - $ref: '#/components/parameters/PageConsolidated'
      responses:
        '200':
          description: Successful response with a list of call events.
          content:
            application/json:
              schema:
                type: object
                title: List Call Events Response
                properties:
                  data:
                    type: array
                    items:
                      $ref: '#/components/schemas/CallEvent'
                  meta:
                    $ref: '#/components/schemas/PaginationMeta'
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


            // Automatically fetches more pages as needed.

            for await (const callEventListResponse of client.callEvents.list())
            {
              console.log(callEventListResponse.call_leg_id);
            }
        - lang: Python
          source: |
            import os
            from telnyx import Telnyx

            client = Telnyx(
                api_key=os.environ.get("TELNYX_API_KEY"),  # This is the default and can be omitted
            )
            page = client.call_events.list()
            page = page.data[0]
            print(page.call_leg_id)
        - lang: Go
          source: "package main\n\nimport (\n\t\"context\"\n\t\"fmt\"\n\n\t\"github.com/team-telnyx/telnyx-go\"\n\t\"github.com/team-telnyx/telnyx-go/option\"\n)\n\nfunc main() {\n\tclient := telnyx.NewClient(\n\t\toption.WithAPIKey(\"My API Key\"),\n\t)\n\tpage, err := client.CallEvents.List(context.TODO(), telnyx.CallEventListParams{})\n\tif err != nil {\n\t\tpanic(err.Error())\n\t}\n\tfmt.Printf(\"%+v\\n\", page)\n}\n"
        - lang: Java
          source: |-
            package com.telnyx.sdk.example;

            import com.telnyx.sdk.client.TelnyxClient;
            import com.telnyx.sdk.client.okhttp.TelnyxOkHttpClient;
            import com.telnyx.sdk.models.callevents.CallEventListPage;
            import com.telnyx.sdk.models.callevents.CallEventListParams;

            public final class Main {
                private Main() {}

                public static void main(String[] args) {
                    TelnyxClient client = TelnyxOkHttpClient.fromEnv();

                    CallEventListPage page = client.callEvents().list();
                }
            }
        - lang: Ruby
          source: |-
            require "telnyx"

            telnyx = Telnyx::Client.new(api_key: "My API Key")

            page = telnyx.call_events.list

            puts(page)
        - lang: PHP
          source: >-
            <?php


            require_once dirname(__DIR__) . '/vendor/autoload.php';


            use Telnyx\Client;

            use Telnyx\Core\Exceptions\APIException;


            $client = new Client(apiKey: getenv('TELNYX_API_KEY') ?: 'My API
            Key');


            try {
              $page = $client->callEvents->list(
                filter: [
                  'applicationName' => ['contains' => 'contains'],
                  'applicationSessionID' => '182bd5e5-6e1a-4fe4-a799-aa6d9a6ab26e',
                  'connectionID' => 'connection_id',
                  'failed' => false,
                  'from' => '+12025550142',
                  'legID' => '182bd5e5-6e1a-4fe4-a799-aa6d9a6ab26e',
                  'name' => 'name',
                  'occurredAt' => [
                    'eq' => '2019-03-29T11:10:00Z',
                    'gt' => '2019-03-29T11:10:00Z',
                    'gte' => '2019-03-29T11:10:00Z',
                    'lt' => '2019-03-29T11:10:00Z',
                    'lte' => '2019-03-29T11:10:00Z',
                  ],
                  'outboundOutboundVoiceProfileID' => '1293384261075731499',
                  'product' => 'texml',
                  'status' => 'init',
                  'to' => '+12025550142',
                  'type' => 'webhook',
                ],
                pageNumber: 0,
                pageSize: 0,
              );

              var_dump($page);
            } catch (APIException $e) {
              echo $e->getMessage();
            }
        - lang: CLI
          source: |-
            telnyx call-events list \
              --api-key 'My API Key'
components:
  parameters:
    FilterConsolidated:
      name: filter
      in: query
      style: deepObject
      explode: true
      description: >-
        Consolidated filter parameter (deepObject style). Originally:
        filter[application_name][contains],
        filter[outbound.outbound_voice_profile_id], filter[leg_id],
        filter[application_session_id], filter[connection_id], filter[product],
        filter[failed], filter[from], filter[to], filter[name], filter[type],
        filter[occurred_at][eq/gt/gte/lt/lte], filter[status]
      schema:
        type: object
        properties:
          application_name:
            type: object
            description: Application name filters
            properties:
              contains:
                type: string
                default: 'null'
                description: >-
                  If present, applications with <code>application_name</code>
                  containing the given value will be returned. Matching is not
                  case-sensitive. Requires at least three characters.
            additionalProperties: false
          outbound.outbound_voice_profile_id:
            type: string
            description: Identifies the associated outbound voice profile.
            example: '1293384261075731499'
            x-format: int64
          leg_id:
            type: string
            format: uuid
            description: The unique identifier of an individual call leg.
          application_session_id:
            type: string
            format: uuid
            description: >-
              The unique identifier of the call session. A session may include
              multiple call leg events.
          connection_id:
            type: string
            description: The unique identifier of the conection.
          product:
            type: string
            enum:
              - call_control
              - fax
              - texml
            example: texml
            description: Filter by product.
          failed:
            type: boolean
            example: false
            description: Delivery failed or not.
          from:
            type: string
            example: '+12025550142'
            description: Filter by From number.
          to:
            type: string
            example: '+12025550142'
            description: Filter by To number.
          name:
            type: string
            description: >-
              If present, conferences will be filtered to those with a matching
              `name` attribute. Matching is case-sensitive
          type:
            type: string
            description: Event type
            enum:
              - command
              - webhook
            example: webhook
          occurred_at:
            type: object
            description: Event occurred_at filters
            properties:
              eq:
                type: string
                example: '2019-03-29T11:10:00Z'
                description: 'Event occurred_at: equal'
              gt:
                type: string
                example: '2019-03-29T11:10:00Z'
                description: 'Event occurred_at: greater than'
              gte:
                type: string
                example: '2019-03-29T11:10:00Z'
                description: 'Event occurred_at: greater than or equal'
              lt:
                type: string
                example: '2019-03-29T11:10:00Z'
                description: 'Event occurred_at: lower than'
              lte:
                type: string
                example: '2019-03-29T11:10:00Z'
                description: 'Event occurred_at: lower than or equal'
            additionalProperties: false
          status:
            type: string
            enum:
              - init
              - in_progress
              - completed
            description: If present, conferences will be filtered by status.
    PageConsolidated:
      name: page
      in: query
      style: deepObject
      explode: true
      description: >-
        Consolidated page parameter (deepObject style). Originally: page[after],
        page[before], page[limit], page[size], page[number]
      schema:
        type: object
        properties:
          after:
            type: string
            default: 'null'
            description: Opaque identifier of next page
          before:
            type: string
            default: 'null'
            description: Opaque identifier of previous page
          limit:
            type: integer
            minimum: 1
            maximum: 250
            default: 20
            description: Limit of records per single page
          size:
            type: integer
            minimum: 1
            maximum: 250
            default: 20
            description: The size of the page
          number:
            type: integer
            minimum: 1
            default: 1
            description: The page number to load
  schemas:
    CallEvent:
      type: object
      title: Call Event
      required:
        - record_type
        - call_leg_id
        - call_session_id
        - event_timestamp
        - name
        - type
        - metadata
      properties:
        record_type:
          type: string
          enum:
            - call_event
          example: call_event
        call_leg_id:
          type: string
          description: Uniquely identifies an individual call leg.
          example: 308fe500-5213-11e9-ace7-02420a0f0668
        call_session_id:
          type: string
          description: >-
            Uniquely identifies the call control session. A session may include
            multiple call leg events.
          example: 308fec30-5213-11e9-9d3f-02420a0f0668
        event_timestamp:
          type: string
          description: Event timestamp
          example: '2019-03-29T11:10:19.127783Z'
        name:
          type: string
          description: Event name
          example: call.hangup
        type:
          type: string
          description: Event type
          enum:
            - command
            - webhook
          example: webhook
        metadata:
          type: object
          description: >-
            Event metadata, which includes raw event, and extra information
            based on event type
      example:
        record_type: call_event
        call_leg_id: 308fe500-5213-11e9-ace7-02420a0f0668
        call_session_id: 308fec30-5213-11e9-9d3f-02420a0f0668
        event_timestamp: '2019-03-29T11:10:19.127783Z'
        name: call.hangup
        type: webhook
        metadata: {}
    PaginationMeta:
      type: object
      properties:
        total_pages:
          type: integer
          example: 3
        total_results:
          type: integer
          example: 55
        page_number:
          type: integer
          example: 2
        page_size:
          type: integer
          example: 25
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
