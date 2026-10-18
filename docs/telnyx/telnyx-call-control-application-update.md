> ## Documentation Index
> Fetch the complete documentation index at: https://developers.telnyx.com/llms.txt
> Use this file to discover all available pages before exploring further.

# Update a call control application

> Updates settings of an existing call control application.



## OpenAPI

````yaml /openapi/source/external/call-control/call-control.json patch /call_control_applications/{id}
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
  /call_control_applications/{id}:
    patch:
      tags:
        - Call Control Applications
      summary: Update a call control application
      description: Updates settings of an existing call control application.
      operationId: UpdateCallControlApplication
      parameters:
        - name: id
          in: path
          description: Identifies the resource.
          required: true
          schema:
            type: string
            example: '1293384261075731499'
            x-format: int64
      requestBody:
        description: Update call control application request.
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/UpdateCallControlApplicationRequest'
      responses:
        '200':
          description: Successful response with details about a call control application.
          content:
            application/json:
              schema:
                type: object
                title: Call Control Application Response
                properties:
                  data:
                    $ref: '#/components/schemas/CallControlApplication'
        '401':
          $ref: '#/components/responses/UnauthorizedResponse'
        '404':
          description: Resource not found
        '409':
          description: >-
            Conflict. Another update to this application is still in progress.
            Wait and retry the request later.
          content:
            application/json:
              schema:
                type: object
                properties:
                  errors:
                    type: array
                    items:
                      type: object
                      properties:
                        detail:
                          type: string
              example:
                errors:
                  - detail: >-
                      A previous update to this connection is still in progress.
                      Please try again later.
        '422':
          description: Bad request
      x-codeSamples:
        - lang: JavaScript
          source: >-
            import Telnyx from 'telnyx';


            const client = new Telnyx({
              apiKey: process.env['TELNYX_API_KEY'], // This is the default and can be omitted
            });


            const callControlApplication = await
            client.callControlApplications.update('1293384261075731499', {
              application_name: 'call-router',
              webhook_event_url: 'https://example.com',
            });


            console.log(callControlApplication.data);
        - lang: Python
          source: |
            import os
            from telnyx import Telnyx

            client = Telnyx(
                api_key=os.environ.get("TELNYX_API_KEY"),  # This is the default and can be omitted
            )
            call_control_application = client.call_control_applications.update(
                id="1293384261075731499",
                application_name="call-router",
                webhook_event_url="https://example.com",
            )
            print(call_control_application.data)
        - lang: Go
          source: "package main\n\nimport (\n\t\"context\"\n\t\"fmt\"\n\n\t\"github.com/team-telnyx/telnyx-go\"\n\t\"github.com/team-telnyx/telnyx-go/option\"\n)\n\nfunc main() {\n\tclient := telnyx.NewClient(\n\t\toption.WithAPIKey(\"My API Key\"),\n\t)\n\tcallControlApplication, err := client.CallControlApplications.Update(\n\t\tcontext.TODO(),\n\t\t\"1293384261075731499\",\n\t\ttelnyx.CallControlApplicationUpdateParams{\n\t\t\tApplicationName: \"call-router\",\n\t\t\tWebhookEventURL: \"https://example.com\",\n\t\t},\n\t)\n\tif err != nil {\n\t\tpanic(err.Error())\n\t}\n\tfmt.Printf(\"%+v\\n\", callControlApplication.Data)\n}\n"
        - lang: Java
          source: >-
            package com.telnyx.sdk.example;


            import com.telnyx.sdk.client.TelnyxClient;

            import com.telnyx.sdk.client.okhttp.TelnyxOkHttpClient;

            import
            com.telnyx.sdk.models.callcontrolapplications.CallControlApplicationUpdateParams;

            import
            com.telnyx.sdk.models.callcontrolapplications.CallControlApplicationUpdateResponse;


            public final class Main {
                private Main() {}

                public static void main(String[] args) {
                    TelnyxClient client = TelnyxOkHttpClient.fromEnv();

                    CallControlApplicationUpdateParams params = CallControlApplicationUpdateParams.builder()
                        .id("1293384261075731499")
                        .applicationName("call-router")
                        .webhookEventUrl("https://example.com")
                        .build();
                    CallControlApplicationUpdateResponse callControlApplication = client.callControlApplications().update(params);
                }
            }
        - lang: Ruby
          source: |-
            require "telnyx"

            telnyx = Telnyx::Client.new(api_key: "My API Key")

            call_control_application = telnyx.call_control_applications.update(
              "1293384261075731499",
              application_name: "call-router",
              webhook_event_url: "https://example.com"
            )

            puts(call_control_application)
        - lang: PHP
          source: >-
            <?php


            require_once dirname(__DIR__) . '/vendor/autoload.php';


            use Telnyx\Client;

            use Telnyx\Core\Exceptions\APIException;


            $client = new Client(apiKey: getenv('TELNYX_API_KEY') ?: 'My API
            Key');


            try {
              $callControlApplication = $client->callControlApplications->update(
                '1293384261075731499',
                applicationName: 'call-router',
                webhookEventURL: 'https://example.com',
                active: false,
                anchorsiteOverride: 'Latency',
                callCostInWebhooks: true,
                dtmfType: 'Inband',
                firstCommandTimeout: true,
                firstCommandTimeoutSecs: 10,
                inbound: [
                  'channelLimit' => 10,
                  'shakenStirEnabled' => true,
                  'sipSubdomain' => 'example',
                  'sipSubdomainReceiveSettings' => 'only_my_connections',
                ],
                outbound: [
                  'channelLimit' => 10, 'outboundVoiceProfileID' => '1293384261075731499'
                ],
                redactDtmfDebugLogging: true,
                tags: ['tag1', 'tag2'],
                webhookAPIVersion: '1',
                webhookEventFailoverURL: 'https://failover.example.com',
                webhookTimeoutSecs: 25,
              );

              var_dump($callControlApplication);
            } catch (APIException $e) {
              echo $e->getMessage();
            }
        - lang: CLI
          source: |-
            telnyx call-control-applications update \
              --api-key 'My API Key' \
              --id 1293384261075731499 \
              --application-name call-router \
              --webhook-event-url https://example.com
components:
  schemas:
    UpdateCallControlApplicationRequest:
      type: object
      title: Update Call Control Application Request
      required:
        - application_name
        - webhook_event_url
      properties:
        application_name:
          type: string
          description: A user-assigned name to help manage the application.
          example: call-router
        webhook_event_url:
          type: string
          format: url
          description: >-
            The URL where webhooks related to this connection will be sent. Must
            include a scheme, such as 'https'.
          example: https://example.com
        call_cost_in_webhooks:
          type: boolean
          description: >-
            Specifies if call cost webhooks should be sent for this Call Control
            Application.
          default: false
        active:
          type: boolean
          description: Specifies whether the connection can be used.
          default: true
        anchorsite_override:
          type: string
          description: >
            <code>Latency</code> directs Telnyx to route media through the site
            with the lowest round-trip time to the user's connection. Telnyx
            calculates this time using ICMP ping messages. This can be disabled
            by specifying a site to handle all media.
          enum:
            - Latency
            - Chicago, IL
            - Ashburn, VA
            - San Jose, CA
            - London, UK
            - Chennai, IN
            - Amsterdam, Netherlands
            - Toronto, Canada
            - Sydney, Australia
          example: Amsterdam, Netherlands
          default: Latency
        dtmf_type:
          type: string
          description: >-
            Sets the type of DTMF digits sent from Telnyx to this Connection.
            Note that DTMF digits sent to Telnyx will be accepted in all
            formats.
          enum:
            - RFC 2833
            - Inband
            - SIP INFO
          example: Inband
          default: RFC 2833
        first_command_timeout:
          type: boolean
          description: >-
            Specifies whether calls to phone numbers associated with this
            connection should hangup after timing out.
          example: true
          default: false
        first_command_timeout_secs:
          type: integer
          description: Specifies how many seconds to wait before timing out a dial command.
          example: 10
          default: 30
        tags:
          type: array
          items:
            type: string
          description: Tags assigned to the Call Control Application.
          example:
            - tag1
            - tag2
        inbound:
          $ref: '#/components/schemas/CallControlApplicationInbound'
        outbound:
          $ref: '#/components/schemas/CallControlApplicationOutbound'
        webhook_api_version:
          type: string
          description: Determines which webhook format will be used, Telnyx API v1 or v2.
          enum:
            - '1'
            - '2'
          example: '1'
          default: '1'
        webhook_event_failover_url:
          type:
            - string
            - 'null'
          format: url
          description: >-
            The failover URL where webhooks related to this connection will be
            sent if sending to the primary URL fails. Must include a scheme,
            such as 'https'.
          example: https://failover.example.com
          default: ''
        webhook_timeout_secs:
          type:
            - integer
            - 'null'
          minimum: 0
          maximum: 30
          description: Specifies how many seconds to wait before timing out a webhook.
          example: 25
          default: null
        redact_dtmf_debug_logging:
          type: boolean
          description: >-
            When enabled, DTMF digits entered by users will be redacted in debug
            logs to protect PII data entered through IVR interactions.
          example: true
          default: false
      example:
        application_name: call-router
        webhook_event_url: https://example.com
        active: false
        anchorsite_override: Latency
        dtmf_type: Inband
        first_command_timeout: true
        first_command_timeout_secs: 10
        inbound:
          channel_limit: 10
          shaken_stir_enabled: true
          sip_subdomain: example
          sip_subdomain_receive_settings: only_my_connections
        outbound:
          channel_limit: 10
          outbound_voice_profile_id: '1293384261075731499'
        webhook_api_version: '1'
        webhook_event_failover_url: https://failover.example.com
        webhook_timeout_secs: 25
        call_cost_in_webhooks: true
        redact_dtmf_debug_logging: true
    CallControlApplication:
      type: object
      title: Call Control Application
      properties:
        active:
          type: boolean
          description: Specifies whether the connection can be used.
          default: true
        anchorsite_override:
          type: string
          description: >
            <code>Latency</code> directs Telnyx to route media through the site
            with the lowest round-trip time to the user's connection. Telnyx
            calculates this time using ICMP ping messages. This can be disabled
            by specifying a site to handle all media.
          enum:
            - Latency
            - Chicago, IL
            - Ashburn, VA
            - San Jose, CA
            - London, UK
            - Chennai, IN
            - Amsterdam, Netherlands
            - Toronto, Canada
            - Sydney, Australia
          example: Amsterdam, Netherlands
          default: Latency
        application_name:
          type: string
          description: A user-assigned name to help manage the application.
          example: call-router
        created_at:
          type: string
          description: ISO 8601 formatted date of when the resource was created
          example: '2018-02-02T22:25:27.521Z'
        dtmf_type:
          type: string
          description: >-
            Sets the type of DTMF digits sent from Telnyx to this Connection.
            Note that DTMF digits sent to Telnyx will be accepted in all
            formats.
          enum:
            - RFC 2833
            - Inband
            - SIP INFO
          example: Inband
          default: RFC 2833
        first_command_timeout:
          type: boolean
          description: >-
            Specifies whether calls to phone numbers associated with this
            connection should hangup after timing out.
          example: true
          default: false
        first_command_timeout_secs:
          type: integer
          description: Specifies how many seconds to wait before timing out a dial command.
          example: 10
          default: 30
        tags:
          type: array
          items:
            type: string
          description: Tags assigned to the Call Control Application.
        id:
          type: string
          example: '1293384261075731499'
          x-format: int64
        inbound:
          $ref: '#/components/schemas/CallControlApplicationInbound'
        outbound:
          $ref: '#/components/schemas/CallControlApplicationOutbound'
        record_type:
          type: string
          enum:
            - call_control_application
          default: call_control_application
        updated_at:
          type: string
          description: ISO 8601 formatted date of when the resource was last updated
          example: '2018-02-02T22:25:27.521Z'
        webhook_api_version:
          type: string
          description: Determines which webhook format will be used, Telnyx API v1 or v2.
          enum:
            - '1'
            - '2'
          example: '1'
          default: '1'
        webhook_event_failover_url:
          type:
            - string
            - 'null'
          format: url
          description: >-
            The failover URL where webhooks related to this connection will be
            sent if sending to the primary URL fails. Must include a scheme,
            such as `https`.
          example: https://failover.example.com
          default: ''
        webhook_event_url:
          type: string
          format: url
          description: >-
            The URL where webhooks related to this connection will be sent. Must
            include a scheme, such as `https`.
          example: https://example.com
        webhook_timeout_secs:
          type:
            - integer
            - 'null'
          minimum: 0
          maximum: 30
          example: 25
          default: null
        call_cost_in_webhooks:
          type: boolean
          description: >-
            Specifies if call cost webhooks should be sent for this Call Control
            Application.
          default: false
        redact_dtmf_debug_logging:
          type: boolean
          description: >-
            When enabled, DTMF digits entered by users will be redacted in debug
            logs to protect PII data entered through IVR interactions.
          example: true
          default: false
      example:
        active: false
        anchorsite_override: Latency
        application_name: call-router
        created_at: '2018-02-02T22:25:27.521Z'
        dtmf_type: Inband
        first_command_timeout: true
        first_command_timeout_secs: 10
        id: '1293384261075731499'
        inbound:
          channel_limit: 10
          shaken_stir_enabled: true
          sip_subdomain: example
          sip_subdomain_receive_settings: only_my_connections
        outbound:
          channel_limit: 10
          outbound_voice_profile_id: '1293384261075731499'
        record_type: call_control_application
        updated_at: '2018-02-02T22:25:27.521Z'
        webhook_api_version: '1'
        webhook_event_failover_url: https://failover.example.com
        webhook_event_url: https://example.com
        webhook_timeout_secs: 25
        call_cost_in_webhooks: false
        redact_dtmf_debug_logging: true
    CallControlApplicationInbound:
      type: object
      title: Call Control Application Inbound
      properties:
        channel_limit:
          type: integer
          description: >-
            When set, this will limit the total number of inbound calls to phone
            numbers associated with this connection.
          example: 10
          default: null
        shaken_stir_enabled:
          type: boolean
          description: >-
            When enabled Telnyx will include Shaken/Stir data in the Webhook for
            new inbound calls.
          default: false
          example: false
        sip_subdomain:
          type: string
          description: >-
            Specifies a subdomain that can be used to receive Inbound calls to a
            Connection, in the same way a phone number is used, from a SIP
            endpoint. Example: the subdomain "example.sip.telnyx.com" can be
            called from any SIP endpoint by using the SIP URI
            "sip:@example.sip.telnyx.com" where the user part can be any
            alphanumeric value. Please note TLS encrypted calls are not allowed
            for subdomain calls.
          example: example
          default: null
        sip_subdomain_receive_settings:
          type: string
          description: >-
            This option can be enabled to receive calls from: "Anyone" (any SIP
            endpoint in the public Internet) or "Only my connections" (any
            connection assigned to the same Telnyx user).
          enum:
            - only_my_connections
            - from_anyone
          example: only_my_connections
          default: from_anyone
    CallControlApplicationOutbound:
      type: object
      title: Call Control Application Outbound
      properties:
        channel_limit:
          type: integer
          description: >-
            When set, this will limit the total number of outbound calls to
            phone numbers associated with this connection.
          example: 10
          default: null
        outbound_voice_profile_id:
          type: string
          description: Identifies the associated outbound voice profile.
          example: '1293384261075731499'
          x-format: int64
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
    UnauthorizedResponse:
      description: >-
        Unauthorized. Authentication failed - the required authentication
        headers were either invalid or not included in the request.
      content:
        application/json:
          schema:
            $ref: '#/components/schemas/Errors'
          example:
            errors:
              - code: '10009'
                title: Authentication failed
                detail: >-
                  The required authentication headers were either invalid or not
                  included in the request.
                meta:
                  url: https://developers.telnyx.com/docs/overview/errors/10009
  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer

````
