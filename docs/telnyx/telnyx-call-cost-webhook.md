> ## Documentation Index
> Fetch the complete documentation index at: https://developers.telnyx.com/llms.txt
> Use this file to discover all available pages before exploring further.

# Call cost

>

This webhook uses Telnyx headers (telnyx-timestamp, telnyx-signature-ed25519) that are compatible with Standard Webhooks specification for SDK generation. Custom validation logic can map these to standard webhook-timestamp and webhook-signature equivalents. See https://github.com/standard-webhooks/standard-webhooks for details.



## OpenAPI

````yaml /openapi/source/external/call-control/call-control.json webhook callCost
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
paths: {}
components:
  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer

````
