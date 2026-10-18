> ## Documentation Index
> Fetch the complete documentation index at: https://developers.telnyx.com/llms.txt
> Use this file to discover all available pages before exploring further.

# Retrieve a phone number

> Returns the detailed configuration and current state of the phone number identified by `id`.



## OpenAPI

````yaml /openapi/source/external/numbers/numbers.json get /phone_numbers/{id}
openapi: 3.1.0
info:
  x-latency-category: responsive
  x-endpoint-cost: light
  version: 2.0.0
  title: Telnyx API
  description: SIP trunking, SMS, MMS, Call Control and Telephony Data Services.
  contact:
    email: support@telnyx.com
servers:
  - url: https://api.telnyx.com/v2
    description: Version 2.0.0 of the Telnyx API
security:
  - bearerAuth: []
tags:
  - name: Phone Number Search
    description: Number search
  - name: Phone Number Reservations
    description: Number reservations
  - name: Phone Number Orders
    description: Number orders
  - name: Inexplicit Number Orders
    description: >-
      Inexplicit number orders for bulk purchasing without specifying exact
      numbers
  - name: Phone Number Order Documents
    description: Number order documents
  - name: Phone Number Configurations
    description: Configure your phone numbers
  - name: Bulk Phone Number Operations
    description: Background jobs performed over a batch of phone numbers
  - name: Inventory Level
    description: Inventory Level
  - name: Phone Number Blocks Background Jobs
    description: Background jobs performed over a phone-numbers block's phone numbers
  - name: Regulatory Requirements
    description: Regulatory Requirements
  - name: Requirement Groups
    description: Requirement Groups
  - name: Country Coverage
    description: Country Coverage
  - name: Callbacks
    description: Callbacks
paths:
  /phone_numbers/{id}:
    get:
      tags:
        - Phone Number Configurations
      summary: Retrieve a phone number
      description: >-
        Returns the detailed configuration and current state of the phone number
        identified by `id`.
      operationId: RetrievePhoneNumber
      parameters:
        - $ref: '#/components/parameters/IntId'
      responses:
        '200':
          description: Successful response with details about a phone number.
          content:
            application/json:
              schema:
                type: object
                title: Phone Number Response
                properties:
                  data:
                    $ref: '#/components/schemas/PhoneNumberDetailed'
        '400':
          $ref: '#/components/responses/BadRequestResponse'
        '401':
          $ref: '#/components/responses/UnauthorizedResponse'
        '404':
          $ref: '#/components/responses/NotFoundResponse'
        '422':
          $ref: '#/components/responses/UnprocessableEntity'
        '500':
          $ref: '#/components/responses/GenericErrorResponse'
      x-codeSamples:
        - lang: JavaScript
          source: >-
            import Telnyx from 'telnyx';


            const client = new Telnyx({
              apiKey: process.env['TELNYX_API_KEY'], // This is the default and can be omitted
            });


            const phoneNumber = await
            client.phoneNumbers.retrieve('1293384261075731499');


            console.log(phoneNumber.data);
        - lang: Python
          source: |
            import os
            from telnyx import Telnyx

            client = Telnyx(
                api_key=os.environ.get("TELNYX_API_KEY"),  # This is the default and can be omitted
            )
            phone_number = client.phone_numbers.retrieve(
                "1293384261075731499",
            )
            print(phone_number.data)
        - lang: Go
          source: "package main\n\nimport (\n\t\"context\"\n\t\"fmt\"\n\n\t\"github.com/team-telnyx/telnyx-go\"\n\t\"github.com/team-telnyx/telnyx-go/option\"\n)\n\nfunc main() {\n\tclient := telnyx.NewClient(\n\t\toption.WithAPIKey(\"My API Key\"),\n\t)\n\tphoneNumber, err := client.PhoneNumbers.Get(context.TODO(), \"1293384261075731499\")\n\tif err != nil {\n\t\tpanic(err.Error())\n\t}\n\tfmt.Printf(\"%+v\\n\", phoneNumber.Data)\n}\n"
        - lang: Java
          source: >-
            package com.telnyx.sdk.example;


            import com.telnyx.sdk.client.TelnyxClient;

            import com.telnyx.sdk.client.okhttp.TelnyxOkHttpClient;

            import com.telnyx.sdk.models.phonenumbers.PhoneNumberRetrieveParams;

            import
            com.telnyx.sdk.models.phonenumbers.PhoneNumberRetrieveResponse;


            public final class Main {
                private Main() {}

                public static void main(String[] args) {
                    TelnyxClient client = TelnyxOkHttpClient.fromEnv();

                    PhoneNumberRetrieveResponse phoneNumber = client.phoneNumbers().retrieve("1293384261075731499");
                }
            }
        - lang: Ruby
          source: |-
            require "telnyx"

            telnyx = Telnyx::Client.new(api_key: "My API Key")

            phone_number = telnyx.phone_numbers.retrieve("1293384261075731499")

            puts(phone_number)
        - lang: PHP
          source: >-
            <?php


            require_once dirname(__DIR__) . '/vendor/autoload.php';


            use Telnyx\Client;

            use Telnyx\Core\Exceptions\APIException;


            $client = new Client(apiKey: getenv('TELNYX_API_KEY') ?: 'My API
            Key');


            try {
              $phoneNumber = $client->phoneNumbers->retrieve('1293384261075731499');

              var_dump($phoneNumber);
            } catch (APIException $e) {
              echo $e->getMessage();
            }
        - lang: CLI
          source: |-
            telnyx phone-numbers retrieve \
              --api-key 'My API Key' \
              --id 1293384261075731499
components:
  parameters:
    IntId:
      name: id
      description: Identifies the resource.
      in: path
      required: true
      schema:
        type: string
        example: '1293384261075731499'
  schemas:
    PhoneNumberDetailed:
      type: object
      example:
        id: '1293384261075731499'
        record_type: phone_number
        phone_number: '+19705555098'
        country_iso_alpha2: US
        status: active
        tags:
          - tag_1
          - tag_2
        external_pin: '1234'
        connection_id: '1293384261075731499'
        connection_name: connection-name
        customer_reference: customer-reference
        messaging_profile_id: abc85f64-5717-4562-b3fc-2c9600000000
        messaging_profile_name: regional-customers
        billing_group_id: 86f58db9-0fe3-4adc-9d1f-46e66e6e9323
        emergency_enabled: true
        emergency_address_id: '1315261609962112019'
        emergency_status: active
        call_forwarding_enabled: true
        cnam_listing_enabled: true
        caller_id_name_enabled: true
        call_recording_enabled: true
        t38_fax_gateway_enabled: true
        phone_number_type: local
        inbound_call_screening: disabled
        purchased_at: '2019-10-23T18:10:00.000Z'
        created_at: '2019-10-23T18:10:00.000Z'
        updated_at: '2019-10-24T18:10:00.000Z'
        hd_voice_enabled: true
        source_type: number_order
        deletion_lock_enabled: false
        activated_at: '2019-10-23T18:10:00.000Z'
      properties:
        id:
          $ref: '#/components/schemas/IntId'
        record_type:
          type: string
          example: phone_number
          description: Identifies the type of the resource.
          readOnly: true
        phone_number:
          type: string
          description: The +E.164-formatted phone number associated with this record.
          readOnly: true
        country_iso_alpha2:
          type: string
          description: The ISO 3166-1 alpha-2 country code of the phone number.
          example: US
          readOnly: true
        status:
          type: string
          description: The phone number's current status.
          enum:
            - purchase-pending
            - purchase-failed
            - port-pending
            - port-failed
            - active
            - deleted
            - emergency-only
            - ported-out
            - port-out-pending
            - requirement-info-pending
            - requirement-info-under-review
            - requirement-info-exception
            - provision-pending
          readOnly: true
        tags:
          type: array
          description: A list of user-assigned tags to help manage the phone number.
          items:
            type: string
        external_pin:
          type:
            - string
            - 'null'
          description: >-
            If someone attempts to port your phone number away from Telnyx and
            your phone number has an external PIN set, Telnyx will attempt to
            verify that you provided the correct external PIN to the winning
            carrier. Note that not all carriers cooperate with this security
            mechanism.
        connection_name:
          type:
            - string
            - 'null'
          description: >-
            The user-assigned name of the connection to be associated with this
            phone number.
          readOnly: true
        connection_id:
          type:
            - string
            - 'null'
          description: Identifies the connection associated with the phone number.
        customer_reference:
          type:
            - string
            - 'null'
          description: A customer reference string for customer look ups.
          example: MY REF 001
        messaging_profile_id:
          type:
            - string
            - 'null'
          description: Identifies the messaging profile associated with the phone number.
        messaging_profile_name:
          type:
            - string
            - 'null'
          description: The name of the messaging profile associated with the phone number.
          example: regional-customers
        billing_group_id:
          type:
            - string
            - 'null'
          description: Identifies the billing group associated with the phone number.
        emergency_enabled:
          type: boolean
          description: Indicates whether emergency services are enabled for this number.
          readOnly: true
        emergency_address_id:
          type:
            - string
            - 'null'
          description: Identifies the emergency address associated with the phone number.
          readOnly: true
        emergency_status:
          type: string
          description: >-
            Indicates the status of the provisioning of emergency services for
            the phone number. This field contains information about activity
            that may be ongoing for a number where it either is being
            provisioned or deprovisioned but is not yet enabled/disabled.
          enum:
            - active
            - deprovisioning
            - disabled
            - provisioning
            - provisioning-failed
        call_forwarding_enabled:
          type: boolean
          default: true
          description: >-
            Indicates if call forwarding will be enabled for this number if
            forwards_to and forwarding_type are filled in. Defaults to true for
            backwards compatibility with APIV1 use of numbers endpoints.
          readOnly: true
        cnam_listing_enabled:
          type: boolean
          description: Indicates whether a CNAM listing is enabled for this number.
          readOnly: true
        caller_id_name_enabled:
          type: boolean
          description: Indicates whether caller ID is enabled for this number.
          readOnly: true
        call_recording_enabled:
          type: boolean
          description: Indicates whether call recording is enabled for this number.
          readOnly: true
        t38_fax_gateway_enabled:
          type: boolean
          description: Indicates whether T38 Fax Gateway for inbound calls to this number.
          readOnly: true
        purchased_at:
          type: string
          description: ISO 8601 formatted date indicating when the resource was purchased.
          readOnly: true
        created_at:
          type: string
          description: ISO 8601 formatted date indicating when the resource was created.
          readOnly: true
          format: date-time
        phone_number_type:
          type: string
          description: >-
            The phone number's type.

            Note: For numbers purchased prior to July 2023 or when fetching a
            number's details immediately after a purchase completes, the legacy
            values `tollfree`, `shortcode` or `longcode` may be returned
            instead.
          enum:
            - local
            - toll_free
            - mobile
            - national
            - shared_cost
            - landline
            - tollfree
            - shortcode
            - longcode
          readOnly: true
        inbound_call_screening:
          type: string
          enum:
            - disabled
            - reject_calls
            - flag_calls
          default: disabled
          description: >-
            The inbound_call_screening setting is a phone number configuration
            option variable that allows users to configure their settings to
            block or flag fraudulent calls. It can be set to disabled,
            reject_calls, or flag_calls. This feature has an additional
            per-number monthly cost associated with it.
        updated_at:
          type: string
          description: ISO 8601 formatted date indicating when the resource was updated.
          readOnly: true
        hd_voice_enabled:
          type: boolean
          description: Indicates whether HD voice is enabled for this number.
          readOnly: true
        source_type:
          description: >-
            Indicates if the phone number was purchased or ported in. For some
            numbers this information may not be available.
          anyOf:
            - type: string
              enum:
                - number_order
                - port_request
            - type: 'null'
          readOnly: true
        deletion_lock_enabled:
          type: boolean
          description: >-
            Indicates whether deletion lock is enabled for this number. When
            enabled, this prevents the phone number from being deleted via the
            API or Telnyx portal.
        activated_at:
          description: >-
            ISO 8601 formatted date indicating when the phone number was first
            activated (transitioned from purchase-pending or port-pending to
            active). Will be null for numbers that have not yet been activated,
            or for legacy numbers activated before this field was tracked.
          anyOf:
            - type: string
              format: date-time
            - type: 'null'
          readOnly: true
      required:
        - id
        - record_type
        - phone_number
        - country_iso_alpha2
        - status
        - tags
        - external_pin
        - created_at
        - phone_number_type
        - purchased_at
        - deletion_lock_enabled
    IntId:
      type: string
      description: Identifies the resource.
      example: '1293384261075731499'
      readOnly: true
    Errors:
      properties:
        errors:
          type: array
          items:
            $ref: '#/components/schemas/Error'
      type: object
    Error:
      properties:
        code:
          type: string
          example: '10007'
        title:
          type: string
          example: Unexpected error
        detail:
          type: string
          example: An unexpected error occured.
        source:
          type: object
          properties:
            pointer:
              description: JSON pointer (RFC6901) to the offending entity.
              type: string
              example: /base
            parameter:
              description: Indicates which query parameter caused the error.
              type: string
        meta:
          type: object
          properties:
            url:
              type: string
              description: URL with additional information on the error.
              example: https://developers.telnyx.com/docs/overview/errors/10015
      type: object
  responses:
    BadRequestResponse:
      description: >-
        Bad request, the request was unacceptable, often due to missing a
        required parameter.
      content:
        application/json:
          schema:
            $ref: '#/components/schemas/Errors'
    UnauthorizedResponse:
      description: Unauthorized
      content:
        application/json:
          schema:
            $ref: '#/components/schemas/Errors'
          examples:
            Authentication Failed:
              value:
                errors:
                  - code: '10009'
                    title: Authentication failed
                    detail: Could not understand the provided credentials.
                    meta:
                      url: https://developers.telnyx.com/docs/overview/errors/10009
    NotFoundResponse:
      description: The requested resource doesn't exist.
      content:
        application/json:
          schema:
            $ref: '#/components/schemas/Errors'
    UnprocessableEntity:
      description: Unprocessable entity. Check the 'detail' field in response for details.
      content:
        application/json:
          schema:
            $ref: '#/components/schemas/Errors'
    GenericErrorResponse:
      description: Unexpected error
      content:
        application/json:
          schema:
            $ref: '#/components/schemas/Errors'
  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer

````
