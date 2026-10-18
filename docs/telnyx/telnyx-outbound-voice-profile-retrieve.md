> ## Documentation Index
> Fetch the complete documentation index at: https://developers.telnyx.com/llms.txt
> Use this file to discover all available pages before exploring further.

# Retrieve an outbound voice profile

> Retrieves the details of an existing outbound voice profile.



## OpenAPI

````yaml /openapi/source/external/outbound-voice-profiles/outbound-voice-profiles.json get /outbound_voice_profiles/{id}
openapi: 3.1.0
info:
  version: 2.0.0
  title: Telnyx API
  x-latency-category: responsive
  x-endpoint-cost: light
  description: SIP trunking, SMS, MMS, Call Control and Telephony Data Services.
  contact:
    email: support@telnyx.com
servers:
  - url: https://api.telnyx.com/v2
    description: Version 2.0.0 of the Telnyx API
security:
  - bearerAuth: []
tags:
  - name: Outbound Voice Profiles
    description: Outbound voice profiles operations
paths:
  /outbound_voice_profiles/{id}:
    get:
      tags:
        - Outbound Voice Profiles
      summary: Retrieve an outbound voice profile
      description: Retrieves the details of an existing outbound voice profile.
      operationId: GetOutboundVoiceProfile
      parameters:
        - $ref: '#/components/parameters/id'
      responses:
        '200':
          description: Successful response
          content:
            application/json:
              schema:
                type: object
                title: Outbound Voice Profile Response
                properties:
                  data:
                    $ref: '#/components/schemas/OutboundVoiceProfile'
        '401':
          description: Unauthorized
        '404':
          description: Resource not found
        '422':
          description: Bad request
      x-codeSamples:
        - lang: JavaScript
          source: >-
            import Telnyx from 'telnyx';


            const client = new Telnyx({
              apiKey: process.env['TELNYX_API_KEY'], // This is the default and can be omitted
            });


            const outboundVoiceProfile = await
            client.outboundVoiceProfiles.retrieve('1293384261075731499');


            console.log(outboundVoiceProfile.data);
        - lang: Python
          source: |
            import os
            from telnyx import Telnyx

            client = Telnyx(
                api_key=os.environ.get("TELNYX_API_KEY"),  # This is the default and can be omitted
            )
            outbound_voice_profile = client.outbound_voice_profiles.retrieve(
                "1293384261075731499",
            )
            print(outbound_voice_profile.data)
        - lang: Go
          source: "package main\n\nimport (\n\t\"context\"\n\t\"fmt\"\n\n\t\"github.com/team-telnyx/telnyx-go\"\n\t\"github.com/team-telnyx/telnyx-go/option\"\n)\n\nfunc main() {\n\tclient := telnyx.NewClient(\n\t\toption.WithAPIKey(\"My API Key\"),\n\t)\n\toutboundVoiceProfile, err := client.OutboundVoiceProfiles.Get(context.TODO(), \"1293384261075731499\")\n\tif err != nil {\n\t\tpanic(err.Error())\n\t}\n\tfmt.Printf(\"%+v\\n\", outboundVoiceProfile.Data)\n}\n"
        - lang: Java
          source: >-
            package com.telnyx.sdk.example;


            import com.telnyx.sdk.client.TelnyxClient;

            import com.telnyx.sdk.client.okhttp.TelnyxOkHttpClient;

            import
            com.telnyx.sdk.models.outboundvoiceprofiles.OutboundVoiceProfileRetrieveParams;

            import
            com.telnyx.sdk.models.outboundvoiceprofiles.OutboundVoiceProfileRetrieveResponse;


            public final class Main {
                private Main() {}

                public static void main(String[] args) {
                    TelnyxClient client = TelnyxOkHttpClient.fromEnv();

                    OutboundVoiceProfileRetrieveResponse outboundVoiceProfile = client.outboundVoiceProfiles().retrieve("1293384261075731499");
                }
            }
        - lang: Ruby
          source: >-
            require "telnyx"


            telnyx = Telnyx::Client.new(api_key: "My API Key")


            outbound_voice_profile =
            telnyx.outbound_voice_profiles.retrieve("1293384261075731499")


            puts(outbound_voice_profile)
        - lang: PHP
          source: >-
            <?php


            require_once dirname(__DIR__) . '/vendor/autoload.php';


            use Telnyx\Client;

            use Telnyx\Core\Exceptions\APIException;


            $client = new Client(apiKey: getenv('TELNYX_API_KEY') ?: 'My API
            Key');


            try {
              $outboundVoiceProfile = $client->outboundVoiceProfiles->retrieve(
                '1293384261075731499'
              );

              var_dump($outboundVoiceProfile);
            } catch (APIException $e) {
              echo $e->getMessage();
            }
        - lang: CLI
          source: |-
            telnyx outbound-voice-profiles retrieve \
              --api-key 'My API Key' \
              --id 1293384261075731499
components:
  parameters:
    id:
      name: id
      description: Identifies the resource.
      in: path
      required: true
      schema:
        type: string
        example: '1293384261075731499'
  schemas:
    OutboundVoiceProfile:
      type: object
      title: Outbound Voice Profile
      required:
        - name
      example:
        id: '1293384261075731499'
        record_type: outbound_voice_profile
        name: office
        connections_count: 12
        traffic_type: conversational
        service_plan: global
        concurrent_call_limit: 10
        enabled: true
        tags:
          - office-profile
        usage_payment_method: rate-deck
        whitelisted_destinations:
          - US
          - BR
          - AU
        max_destination_rate: 10
        daily_spend_limit: '100.00'
        daily_spend_limit_enabled: true
        call_recording:
          call_recording_type: by_caller_phone_number
          call_recording_caller_phone_numbers:
            - '+19705555098'
          call_recording_channels: dual
          call_recording_format: mp3
        billing_group_id: 6a09cdc3-8948-47f0-aa62-74ac943d6c58
        calling_window:
          start_time: 08:00:00.00Z
          end_time: 20:00:00.00Z
          calls_per_cld: 5
        created_at: '2018-02-02T22:25:27.521Z'
        updated_at: '2018-02-02T22:25:27.521Z'
      properties:
        id:
          type: string
          description: Identifies the resource.
          example: '1293384261075731499'
        record_type:
          type: string
          description: Identifies the type of the resource.
          example: outbound_voice_profile
        name:
          type: string
          description: A user-supplied name to help with organization.
          example: office
          minLength: 3
        connections_count:
          type: integer
          description: Amount of connections associated with this outbound voice profile.
          example: 12
        traffic_type:
          $ref: '#/components/schemas/TrafficType'
        service_plan:
          $ref: '#/components/schemas/ServicePlan'
        concurrent_call_limit:
          type:
            - integer
            - 'null'
          description: >-
            Must be no more than your global concurrent call limit. Null means
            no limit.
          example: 10
        enabled:
          type: boolean
          description: >-
            Specifies whether the outbound voice profile can be used. Disabled
            profiles will result in outbound calls being blocked for the
            associated Connections.
          example: true
          default: true
        tags:
          type: array
          items:
            type: string
          example:
            - office-profile
        usage_payment_method:
          $ref: '#/components/schemas/UsagePaymentMethod'
        whitelisted_destinations:
          type: array
          items:
            type: string
          description: >-
            The list of destinations you want to be able to call using this
            outbound voice profile formatted in alpha2.
          example:
            - US
            - BR
            - AU
          default:
            - US
            - CA
        max_destination_rate:
          type: number
          description: >-
            Maximum rate (price per minute) for a Destination to be allowed when
            making outbound calls.
        daily_spend_limit:
          type: string
          description: >-
            The maximum amount of usage charges, in USD, you want Telnyx to
            allow on this outbound voice profile in a day before disallowing new
            calls.
          example: '100.00'
        daily_spend_limit_enabled:
          type: boolean
          description: >-
            Specifies whether to enforce the daily_spend_limit on this outbound
            voice profile.
          example: true
          default: false
        call_recording:
          $ref: '#/components/schemas/OutboundCallRecording'
        billing_group_id:
          type:
            - string
            - 'null'
          format: uuid
          description: >-
            The ID of the billing group associated with the outbound proflile.
            Defaults to null (for no group assigned).
          example: 6a09cdc3-8948-47f0-aa62-74ac943d6c58
          default: null
        calling_window:
          type: object
          description: >-
            (BETA) Specifies the time window and call limits for calls made
            using this outbound voice profile. Note that all times are UTC in
            24-hour clock time.
          example:
            start_time: 08:00:00.00Z
            end_time: 20:00:00.00Z
            calls_per_cld: 5
          properties:
            start_time:
              type: string
              description: >-
                (BETA) The UTC time of day (in HH:MM format, 24-hour clock) when
                calls are allowed to start.
              example: 08:00:00.00Z
            end_time:
              type: string
              description: >-
                (BETA) The UTC time of day (in HH:MM format, 24-hour clock) when
                calls are no longer allowed to start.
              example: 20:00:00.00Z
            calls_per_cld:
              type: integer
              description: >-
                (BETA) The maximum number of calls that can be initiated to a
                single called party (CLD) within the calling window. A null
                value means no limit.
              example: 5
        created_at:
          type: string
          description: >-
            ISO 8601 formatted date-time indicating when the resource was
            created.
          example: '2018-02-02T22:25:27.521Z'
        updated_at:
          type: string
          description: >-
            ISO 8601 formatted date-time indicating when the resource was
            updated.
          example: '2018-02-02T22:25:27.521Z'
    TrafficType:
      type: string
      description: Specifies the type of traffic allowed in this profile.
      enum:
        - conversational
      example: conversational
      default: conversational
    ServicePlan:
      type: string
      description: Indicates the coverage of the termination regions.
      enum:
        - global
      example: global
      default: global
    UsagePaymentMethod:
      type: string
      description: Setting for how costs for outbound profile are calculated.
      enum:
        - rate-deck
      example: rate-deck
      default: rate-deck
    OutboundCallRecording:
      type: object
      example:
        call_recording_type: by_caller_phone_number
        call_recording_caller_phone_numbers:
          - '+19705555098'
        call_recording_channels: dual
        call_recording_format: mp3
      properties:
        call_recording_type:
          type: string
          description: Specifies which calls are recorded.
          enum:
            - all
            - none
            - by_caller_phone_number
        call_recording_caller_phone_numbers:
          type: array
          items:
            type: string
          description: >-
            When call_recording_type is 'by_caller_phone_number', only outbound
            calls using one of these numbers will be recorded. Numbers must be
            specified in E164 format.
          example:
            - '+19705555098'
        call_recording_channels:
          type: string
          description: >-
            When using 'dual' channels, the final audio file will be a stereo
            recording with the first leg on channel A, and the rest on channel
            B.
          example: dual
          default: single
          enum:
            - single
            - dual
        call_recording_format:
          type: string
          description: The audio file format for calls being recorded.
          example: mp3
          default: wav
          enum:
            - wav
            - mp3
  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer
      bearerFormat: JWT

````
