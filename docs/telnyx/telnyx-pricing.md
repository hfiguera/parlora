Warning: truncated output (original token count: 176150)
Total output lines: 12414

# Telnyx Pricing for AI Agents

Canonical markdown summary of Telnyx pricing for AI agents, crawlers, and programmatic evaluators.

## Endpoint Summary

- **Canonical markdown:** https://telnyx.com/pricing.md
- **AI markdown alias:** https://telnyx.com/ai/pricing.md
- **Machine-readable JSON:** https://telnyx.com/ai/pricing.json
- **Economics JSON alias:** https://telnyx.com/ai/economics.json
- **API catalog:** https://telnyx.com/ai/api-catalog.json
- **Discovery index:** https://telnyx.com/.well-known/ai-capabilities.json
- **AI endpoint sitemap:** https://telnyx.com/ai/ai-sitemap.xml
- **Cache:** `s-maxage=300, stale-while-revalidate`
- **CORS:** public `GET` and `OPTIONS`

## How to Consume This Endpoint

Use markdown when an agent needs concise human-readable context and JSON when it needs stable structured fields.

```bash
curl -H 'Accept: text/markdown' https://telnyx.com/pricing.md
curl -H 'Accept: application/json' https://telnyx.com/ai/pricing.json
curl https://telnyx.com/ai/api-catalog.json
```

The JSON payload currently uses the AI registry economics data as its source of truth. Live billing API integration is planned so this endpoint can align with runtime country/currency pricing tables.

## Product Pricing Summary

Usage-based pricing with no commitments. Volume discounts available on committed plans.

## SIP Trunking

| Metric | Price | Type | Note |
|--------|-------|------|------|
| Sip Outbound Usd Per Min | From $0.005/min | starting_at |  |
| Sip Inbound Usd Per Min | From $0.0032/min | starting_at |  |

## Voice API

| Metric | Price | Type | Note |
|--------|-------|------|------|
| Voice Api Outbound Usd Per Min | $0.002/min | flat | Platform fee; SIP trunking fees apply on top |
| Voice Api Inbound Local Usd Per Min | $0.002/min | flat | Platform fee for local numbers; SIP trunking fees apply on top |
| Voice Api Inbound Toll Free Usd Per Min | $0.002/min | flat | Platform fee for toll-free numbers; SIP trunking fees apply on top |
| Call Recording Usd Per Min | $0.002/min | flat |  |
| Media Streaming Usd Per Min | $0.0035/min | flat | Media streaming over WebSockets |
| Conference Usd Per Participant Per Min | $0.002/participant/min | flat |  |

## Text-to-Speech

| Provider | Price per Character |
|----------|-------------------|
| Telnyx | $0.000006/char |
| Amazon Polly (Standard) | $0.000009/char |
| Telnyx HD Voices | $0.000048/char |
| Amazon Polly (Neural) | $0.000024/char |
| MiniMax speech-2.8-turbo | $0.000034/char |
| Rime | $0.000020/char |
| Inworld Mini | $0.0000055/char |
| Inworld Max | $0.000010/char |
| Qwen3TTS | $0.000032/char |
| Telnyx Ultra | $0.000032/char |
| Resemble | $0.000008/char |
| Murf | $0.000008/char |
| ElevenLabs | BYO API key (billed by ElevenLabs) |
| Azure Neural HD | $0.000050/char |

## Speech-to-Text

| Provider | Price per Minute |
|----------|-----------------|
| Telnyx | $0.015/min |
| Deepgram Nova 2 | $0.0074/min |
| Deepgram Nova 3 | $0.0074/min |
| Deepgram Flux | $0.0074/min |
| Google | $0.017/min |
| Azure | $0.027/min |
| AssemblyAI | $0.007/min |
| Grok (xAI) | $0.0033/min |
| Parakeet | $0.0015/min |
| Soniox | $0.002/min |
| Speechmatics | $0.0035/min |
| Humain | $0.007/min |
| Basira | $0.007/min |
| Cohere Arabic | $0.0015/min |

## Voice AI / Conversational AI

| Metric | Price | Type | Note |
|--------|-------|------|------|
| Voice Ai Agent Usd Per Min | $0.05/min | flat | Includes SIP + STT + LLM inference + TTS on single platform |
| Voice Ai Storage Usd Per Gib Per Month | $0.006/GiB/mo | flat | Cloud Storage for Conversational AI |

## AI Inference

| Model | Pricing |
|-------|---------|
| Kimi K2.6 | $0.95/1M input · $0.16/1M cached input · $4.00/1M output |
| GLM-5.1-FP8 | $1.40/1M input · $0.26/1M cached input · $4.40/1M output |
| MiniMax-M3 | $0.51/1M input · $0.102/1M cached input · $2.04/1M output |
| GTE-Large embedding | $0.0001/1K tokens |
| Speech to text | $0.003/minute |
| AI-enabled storage and retrieval | $0.02/GB/day |

## Messaging

| Metric | Price | Type | Note |
|--------|-------|------|------|
| Sms Outbound Usd Per Msg | From $0.004/msg | starting_at |  |

## Fax

| Metric | Price | Type | Note |
|--------|-------|------|------|
| Fax Outbound Usd Per Page | $0.007/page | flat | Send a fax |
| Fax Inbound Usd Per Page | $0.007/page | flat | Receive a fax |

## Numbers & Lookup

| Metric | Price | Type | Note |
|--------|-------|------|------|
| Number Monthly Usd | $1.00/mo | flat | Local number base rate (US); volume discounts start at $0.79/mo |
| Number Lookup Usd Per Query | From $0.0015/query | starting_at |  |

## Plans

### Pay-as-you-go

- **Min. commitment:** $0/mo
- No minimum commitment
- All products available
- Community support
- Standard rate limits

### Committed

- **Min. commitment:** $500/mo
- Volume discounts
- Dedicated account manager
- Priority support
- Higher rate limits
- Custom SLA

### Enterprise

- **Min. commitment:** $5000/mo
- Custom pricing
- Dedicated infrastructure
- 24/7 premium support
- Unlimited rate limits
- Custom SLA with credits
- Dedicated IP addressing
- Private network interconnect

## Rate Limits

- SMS: 50/sec
- Voice: 500 concurrent
- API: 100/sec
- _Higher limits available on committed and enterprise plans_

---

*Canonical markdown: [pricing.md](/pricing.md). AI markdown alias: [/ai/pricing.md](/ai/pricing.md). Structured JSON: [/ai/pricing.json](/ai/pricing.json) and [/ai/economics.json](/ai/economics.json). See [API catalog](/ai/api-catalog.json) for all machine-readable endpoints.*

## Live Website Pricing Detail

Complete customer-facing rate sheet: 32 products, 5977 rates, all USD.
Every rate is read live from the public pricing API
(`GET https://api.telnyx.com/v2/pricing/products/{slug}`) — the same source
the /pricing/\* pages render, cached for at most 24 hours. Non-USD figures
shown elsewhere on telnyx.com are derived from these at the daily rate.

Outbound calling is priced by destination and is not listed here — see https://telnyx.com/pricing/elastic-sip. Items marked "Rate deck" are priced the same way.

Deliberately not listed: `elastic-sip-outbound` (priced by destination — see /pricing/elastic-sip).

### 10dlc (92 rates)

#### Global

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Auth Plus appeal fee for a brand in 10DLC | $11 | brand | otc | — | — |
| Auth Plus fee for a brand in 10DLC | $12.5 | brand | otc | — | — |
| Enhanced vetting fee for a brand in 10DLC | $101.5 | brand | otc | — | — |
| Mail political vetting fee for a brand in 10DLC | $96 | brand | otc | — | — |
| 10DLC MMS Origination Carrier Fee for T-Mobile | $0 | part | usage | — | — |
| 10DLC MMS Termination Carrier Fee for AT&T - Message Class A | $0.0035 | part | usage | — | — |
| 10DLC MMS Termination Carrier Fee for AT&T - Message Class B | $0.0035 | part | usage | — | — |
| 10DLC MMS Termination Carrier Fee for AT&T - Message Class C | $0.0035 | part | usage | — | — |
| 10DLC MMS Termination Carrier Fee for AT&T - Message Class D | $0.0035 | part | usage | — | — |
| 10DLC MMS Termination Carrier Fee for AT&T - Message Class E | $0.0035 | part | usage | — | — |
| 10DLC MMS Termination Carrier Fee for AT&T - Message Class F | $0.0035 | part | usage | — | — |
| 10DLC MMS Termination Carrier Fee for AT&T - Message Class G | $0.0035 | part | usage | — | — |
| 10DLC MMS Termination Carrier Fee for AT&T - Message Class P | $0 | part | usage | — | — |
| 10DLC MMS Termination Carrier Fee for AT&T - Message Class Q | $0.0035 | part | usage | — | — |
| 10DLC MMS Termination Carrier Fee for AT&T - Message Class S | $0.004 | part | usage | — | — |
| 10DLC MMS Termination Carrier Fee for AT&T - Message Class T | $0.005 | part | usage | — | — |
| 10DLC MMS Termination Carrier Fee for AT&T - Message Class W | $0 | part | usage | — | — |
| 10DLC MMS Termination Carrier Fee for AT&T - Message Class X | $0 | part | usage | — | — |
| 10DLC MMS Termination Carrier Fee for AT&T - Message Class Y | $0 | part | usage | — | — |
| 10DLC MMS Termination Carrier Fee for AT&T - Message Class Z | $0.0035 | part | usage | — | — |
| 10DLC MMS Termination Carrier Fee for T-Mobile | $0 | part | usage | — | — |
| 10DLC MMS Termination Carrier Fee for U.S. Cellular | $0.01 | part | usage | — | — |
| 10DLC MMS Termination Carrier Fee for Verizon | $0.0052 | part | usage | — | — |
| Political vetting fee for a brand in 10DLC | $66 | brand | otc | — | — |
| Registration fee for a Sole Proprietor brand in 10DLC | $4 | brand | otc | — | — |
| 10DLC SMS Origination Carrier Fee for T-Mobile | $0.003 | part | usage | — | — |
| 10DLC SMS Termination Carrier Fee for AT&T - Message Class A | $0.002 | part | usage | — | — |
| 10DLC SMS Termination Carrier Fee for AT&T - Message Class B | $0.003 | part | usage | — | — |
| 10DLC SMS Termination Carrier Fee for AT&T - Message Class C | $0.002 | part | usage | — | — |
| 10DLC SMS Termination Carrier Fee for AT&T - Message Class D | $0.003 | part | usage | — | — |
| 10DLC SMS Termination Carrier Fee for AT&T - Message Class E | $0.002 | part | usage | — | — |
| 10DLC SMS Termination Carrier Fee for AT&T - Message Class F | $0.003 | part | usage | — | — |
| 10DLC SMS Termination Carrier Fee for AT&T - Message Class G | $0.002 | part | usage | — | — |
| 10DLC SMS Termination Carrier Fee for AT&T - Message Class P | $0 | part | usage | — | — |
| 10DLC SMS Termination Carrier Fee for AT&T - Message Class Q | $0.002 | part | usage | — | — |
| 10DLC SMS Termination Carrier Fee for AT&T - Message Class S | $0.004 | part | usage | — | — |
| 10DLC SMS Termination Carrier Fee for AT&T - Message Class T | $0.004 | part | usage | — | — |
| 10DLC SMS Termination Carrier Fee for AT&T - Message Class W | $0 | part | usage | — | — |
| 10DLC SMS Termination Carrier Fee for AT&T - Message Class X | $0 | part | usage | — | — |
| 10DLC SMS Termination Carrier Fee for AT&T - Message Class Y | $0 | part | usage | — | — |
| 10DLC SMS Termination Carrier Fee for AT&T - Message Class Z | $0.002 | part | usage | — | — |
| 10DLC SMS Termination Carrier Fee for T-Mobile | $0.003 | part | usage | — | — |
| 10DLC SMS Termination Carrier Fee for U.S. Cellular | $0.005 | part | usage | — | — |
| 10DLC SMS Termination Carrier Fee for Verizon | $0.00305 | part | usage | — | — |

#### US

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| A Monthly Passthrough Charge by the TCR For Registring a Campaign of type: 2FA | $10 | campaign | mrc | — | — |
| A Monthly Passthrough Charge by the TCR For Registring a Campaign of type: Account Notifications | $10 | campaign | mrc | — | — |
| A Monthly Passthrough Charge by the TCR For Registring a Campaign of type: Agents and Franchises | $30 | campaign | mrc | — | — |
| A Monthly Passthrough Charge by the TCR For Registring a Campaign of type: Carrier Exemptions | $10 | campaign | mrc | — | — |
| Registration fee for a 10DLC charity campaign | $3 | campaign | mrc | — | — |
| A Monthly Passthrough Charge by the TCR For Registring a Campaign of type: Customer Care | $10 | campaign | mrc | — | — |
| A Monthly Passthrough Charge by the TCR For Registring a Campaign of type: Delivery Notifications | $10 | campaign | mrc | — | — |
| A Monthly Passthrough Charge by the TCR For Registring a Campaign of type: Emergency | $5 | campaign | mrc | — | — |
| A Monthly Passthrough Charge by the TCR For Registring a Campaign of type: Fraud Alert Messaging | $10 | campaign | mrc | — | — |
| A Monthly Passthrough Charge by the TCR For Registring a Campaign of type: Higher Education | $10 | campaign | mrc | — | — |
| A Monthly Passthrough Charge by the TCR For Registring a Campaign of type: K-12 Education | $10 | campaign | mrc | — | — |
| Fee associated for a Low Volume mixed use campaign | $1.5 | campaign | mrc | — | — |
| A Monthly Passthrough Charge by the TCR For Registring a Campaign of type: Marketing | $10 | campaign | mrc | — | — |
| A Monthly Passthrough Charge by the TCR For Registring a Campaign of type: Mixed | $10 | campaign | mrc | — | — |
| A Monthly Passthrough Charge by the TCR For Registring a Campaign of type: Sole Proprietor | $0 | campaign | mrc | — | — |
| A Monthly Passthrough Charge by the TCR For Registring a Campaign of type: Political | $10 | campaign | mrc | — | — |
| A Monthly Passthrough Charge by the TCR For Registring a Campaign of type: Polling and Voting | $10 | campaign | mrc | — | — |
| A Monthly Passthrough Charge by the TCR For Registring a Campaign of type: Proxy | $10 | campaign | mrc | — | — |
| A Monthly Passthrough Charge by the TCR For Registring a Campaign of type: Public Service Announcements | $10 | campaign | mrc | — | — |
| Registration fee for a 10DLC campaign | $10 | campaign | mrc | — | — |
| A Monthly Passthrough Charge by the TCR For Registring a Campaign of type: Security Alert | $10 | campaign | mrc | — | — |
| A Monthly Passthrough Charge by the TCR For Registring a Campaign of type: Social | $10 | campaign | mrc | — | — |
| Registration fee for a 10DLC Sole Proprietor campaign | $2 | campaign | mrc | — | — |
| A Monthly Passthrough Charge by the TCR For Registring a Campaign of type: Sweepstakes | $10 | campaign | mrc | — | — |
| 10DLC Campaign Activation Fee by Syniverse | $15 | campaign | otc | — | — |
| 10DLC one time Registration fee for T-Mobile | $50 | campaign | otc | — | — |
| 10DLC Campaign Resubmission Fee - charge is per campaign. | $15 | campaign | otc | — | — |
| 10DLC Campaign Service Activation or Migration Fee by T-Mobile | $50 | campaign | otc | — | — |
| 10DLC MMS Origination Unregistered Carrier Fee for ATT | $0 | part | usage | origination | — |
| 10DLC MMS Origination Unregistered Carrier Fee for Sprint | $0.013 | part | usage | origination | — |
| 10DLC MMS Origination Unregistered Carrier Fee for T-Mobile | $0.021 | part | usage | origination | — |
| 10DLC MMS Termination Unregistered Carrier Fee for ATT | $0.015 | part | usage | termination | — |
| 10DLC MMS Termination Unregistered Carrier Fee for Sprint | $0.014 | part | usage | termination | — |
| 10DLC MMS Termination Unregistered Carrier Fee for T-Mobile | $0.021 | part | usage | termination | — |
| 10DLC MMS Termination Unregistered Carrier Fee for Verizon | $0.0052 | part | usage | termination | — |
| Registration fee for a brand in 10DLC | $4.5 | brand | otc | — | — |
| 10DLC SMS Termination Unregistered Carrier Fee for AT&T | $0.01 | part | usage | origination | — |
| 10DLC SMS Origination Unregistered Carrier Fee for Sprint | $0.004 | part | usage | origination | — |
| 10DLC SMS Origination Unregistered Carrier Fee for T-Mobile | $0.012 | part | usage | origination | — |
| 10DLC SMS Origination Unregistered Carrier Fee for AT&T | $0.01 | part | usage | termination | — |
| 10DLC SMS Termination Unregistered Carrier Fee for Sprint | $0.005 | part | usage | termination | — |
| 10DLC SMS Termination Unregistered Carrier Fee for T-Mobile | $0.012 | part | usage | termination | — |
| 10DLC SMS Termination Unregistered Carrier Fee for Verizon | $0.01005 | part | usage | termination | — |
| Fee for the upfront cost of the first 3 months of a Charity campaign | $15 | campaign | otc | — | — |
| Fee for the upfront cost of the first 3 months of a Low Volume mixed use campaign | $4.5 | campaign | otc | — | — |
| Fee for the upfront cost of the first 3 months of a Regular campaign | $30 | campaign | otc | — | — |
| Fee for the upfront cost of the first 3 months of a Sole Proprietor campaign | $1 | campaign | otc | — | — |
| Vetting fee for a brand in 10DLC | $41.5 | brand | otc | — | — |

### Account Services (`account-services`, 5 rates)

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| French Association de la Portabilité des Numéros Fixes integration | $368.17 | integration | mrc | — | — |
| Business Associate Agreement Monthly Recurring Cost | $2500 | package | mrc | — | — |
| French Mécanismes d’Authentification des Numéros STIR/SHAKEN Integration | $252.32 | integration | mrc | — | — |
| Support services minimum commitment MRC | $10000 | package | mrc | — | — |
| Support services usage-based upcharge | $10000 | package | mrc | — | — |

### Alphanumeric Sender Id (`alphanumeric-sender-id`, 211 rates)

#### AC

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Ascension Islands Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### AD

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Andorra Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### AE

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| United Arab Emirates Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### AF

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Afghanistan Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### AL

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Albania Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### AM

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Armenia Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### AO

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Angola Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### AR

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Argentina Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### AT

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Austria Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### AU

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Australia Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### AW

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Aruba Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### AZ

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Azerbaijan Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### BA

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Bosnia and Herzegovina Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### BD

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Bangladesh Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### BE

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Belgium Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### BF

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Burkina Faso Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### BG

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Bulgaria Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### BH

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Bahrain Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### BI

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Burundi Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### BJ

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Benin Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### BL

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Saint Barthélemy Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### BN

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Brunei Darussalam Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### BO

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Bolivia, Plurinational State of Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### BQ

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Bonaire, Sint Eustatius and Saba Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### BR

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Brazil Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### BT

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Bhutan Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### BW

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Botswana Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### BY

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Belarus Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### BZ

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Belize Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### CD

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Congo, The Democratic Republic of the Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### CF

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Central African Republic Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### CG

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Congo Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### CH

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Switzerland Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### CI

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Ivory Coast Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### CK

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Cook Islands Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### CL

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Chile Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### CM

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Cameroon Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### CN

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| China Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### CO

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Colombia Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### CR

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Costa Rica Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### CU

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Cuba Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### CV

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Cabo Verde Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### CW

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Curaçao Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### CY

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Cyprus Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### CZ

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Czechia Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### DE

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Germany Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### DJ

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Djibouti Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### DK

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Denmark Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### DZ

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Algeria Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### EC

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Ecuador Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### EE

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Estonia Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### EG

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Egypt Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### ER

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Eritrea Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### ES

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Spain Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### ET

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Ethiopia Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### FI

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Finland Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### FJ

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Fiji Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### FK

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Falkland Islands (Malvinas) Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### FM

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Micronesia, Federated States of Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### FO

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Faroe Islands Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### FR

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| France Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### GA

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Gabon Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### GB

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| United Kingdom Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### GE

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Georgia Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### GF

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| French Guiana Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### GG

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Guernsey Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### GH

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Ghana Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### GI

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Gibraltar Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### GL

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Greenland Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### GM

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Gambia Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### GN

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Guinea Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### GP

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Guadeloupe Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### GQ

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Equatorial Guinea Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### GR

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Greece Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### GT

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Guatemala Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### GW

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Guinea-Bissau Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### GY

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Guyana Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### HK

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Hong Kong Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### HN

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Honduras Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### HR

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Croatia Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### HT

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Haiti Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### HU

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Hungary Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### ID

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Indonesia Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### IE

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Ireland Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### IL

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Israel Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### IM

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Isle of Man Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### IN

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| India Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### IO

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| British Indian Ocean Territory Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### IQ

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Iraq Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### IR

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Iran, Islamic Republic of Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### IS

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Iceland Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### IT

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Italy Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### JE

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Jersey Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### JO

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Jordan Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### JP

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Japan Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### KE

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Kenya Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### KG

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Kyrgyzstan Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### KH

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Cambodia Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### KI

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Kiribati Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### KM

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Comoros Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### KP

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Korea Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### KR

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Korea, Republic of Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### KW

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Kuwait Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### KZ

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Kazakhstan Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### LA

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Lao Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### LB

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Lebanon Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### LI

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Liechtenstein Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### LK

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Sri Lanka Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### LR

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Liberia Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### LS

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Lesotho Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### LT

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Lithuania Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### LU

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Luxembourg Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### LV

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Latvia Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### LY

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Libya Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### MA

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Morocco Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### MC

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Monaco Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### MD

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Moldova, Republic of Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### ME

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Montenegro Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### MG

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Madagascar Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### MH

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Marshall Islands Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### MK

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| North Macedonia Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### ML

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Mali Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### MM

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Myanmar Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### MN

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Mongolia Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### MO

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Macao Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### MQ

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Martinique Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### MR

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Mauritania Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### MT

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Malta Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### MU

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Mauritius Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### MV

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Maldives Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### MW

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Malawi Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### MX

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Mexico Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### MY

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Malaysia Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### MZ

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Mozambique Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### NA

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Namibia Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### NC

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| New Caledonia Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### NE

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Niger Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### NF

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Norfolk Island Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### NG

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Nigeria Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### NI

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Nicaragua Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### NL

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Netherlands Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### NO

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Norway Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### NP

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Nepal Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### NR

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Nauru Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### NU

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Niue Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### NZ

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| New Zealand Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### OM

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Oman Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### PA

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Panama Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### PE

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Peru Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### PF

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| French Polynesia Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### PG

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Papua New Guinea Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### PH

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Philippines Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### PK

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Pakistan Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### PL

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Poland Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### PM

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Saint Pierre and Miquelon Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### PS

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Palestine, State of Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### PT

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Portugal Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### PW

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Palau Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### PY

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Paraguay Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### QA

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Qatar Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### RE

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Réunion Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### RO

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Romania Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### RS

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Serbia Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck (not flat). | $0 | part | usage | termination | — |

#### RU

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Russian Federation Alphanumeric tarrifed SMS Outbound Usage Cost- amount is per part - amount is determined by a rate deck …146150 tokens truncated…essage | usage | — | — |
| WhatsApp Meta marketing fee for MU - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for MU - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for MU - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for MV - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for MV - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for MV - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for MV - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for MW - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for MW - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for MW - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for MW - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for MX - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for MX - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for MX - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for MX - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for MY - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication international fee for MY - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for MY - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for MY - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for MY - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for MZ - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for MZ - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for MZ - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for MZ - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for NA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for NA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for NA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for NA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for NC - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for NC - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for NC - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for NC - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for NE - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for NE - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for NE - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for NE - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for NF - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for NF - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for NF - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for NF - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for NG - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication international fee for NG - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for NG - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for NG - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for NG - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for NI - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for NI - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for NI - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for NI - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for NL - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for NL - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for NL - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for NL - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for NO - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for NO - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for NO - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for NO - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for NP - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for NP - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for NP - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for NP - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for NR - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for NR - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for NR - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for NR - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for NU - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for NU - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for NU - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for NU - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for NZ - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for NZ - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for NZ - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for NZ - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for OM - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for OM - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for OM - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for OM - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for PA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for PA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for PA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for PA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for PE - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for PE - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for PE - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for PE - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for PG - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for PG - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for PG - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for PG - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for PH - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for PH - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for PH - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for PH - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for PK - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication international fee for PK - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for PK - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for PK - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for PK - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for PL - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for PL - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for PL - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for PL - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for PM - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for PM - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for PM - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for PM - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for PR - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for PR - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for PR - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for PR - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for PS - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for PS - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for PS - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for PS - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for PT - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for PT - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for PT - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for PT - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for PW - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for PW - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for PW - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for PW - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for PY - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for PY - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for PY - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for PY - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for QA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for QA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for QA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for QA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for RE - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for RE - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for RE - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for RE - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for RO - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for RO - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for RO - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for RO - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for RS - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for RS - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for RS - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for RS - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for RU - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for RU - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for RU - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for RU - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for RW - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for RW - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for RW - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for RW - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for SA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication international fee for SA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for SA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for SA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for SA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for SC - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for SC - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for SC - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for SC - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for SD - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for SD - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for SD - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for SD - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for SE - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for SE - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for SE - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for SE - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for SG - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for SG - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for SG - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for SG - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for SI - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for SI - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for SI - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for SI - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for SJ - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for SJ - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for SJ - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for SJ - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for SK - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for SK - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for SK - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for SK - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for SL - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for SL - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for SL - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for SL - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for SM - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for SM - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for SM - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for SM - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for SN - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for SN - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for SN - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for SN - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for SO - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for SO - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for SO - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for SO - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for SR - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for SR - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for SR - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for SR - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for SS - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for SS - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for SS - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for SS - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for SV - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for SV - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for SV - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for SV - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for SX - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for SX - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for SX - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for SX - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for SY - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for SY - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for SY - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for SY - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for SZ - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for SZ - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for SZ - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for SZ - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for TC - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for TC - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for TC - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for TC - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for TD - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for TD - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for TD - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for TD - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for TG - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for TG - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for TG - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for TG - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for TH - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for TH - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for TH - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for TH - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for TJ - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for TJ - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for TJ - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for TJ - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for TK - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for TK - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for TK - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for TK - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for TL - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for TL - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for TL - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for TL - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for TM - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for TM - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for TM - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for TM - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for TN - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for TN - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for TN - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for TN - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for TO - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for TO - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for TO - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for TO - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for TR - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for TR - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for TR - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for TR - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for TT - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for TT - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for TT - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for TT - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for TV - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for TV - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for TV - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for TV - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for TW - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for TW - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for TW - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for TW - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for TZ - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for TZ - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for TZ - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for TZ - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for UA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for UA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for UA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for UA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for UG - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for UG - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for UG - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for UG - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for UM - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for UM - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for UM - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for UM - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for US - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for US - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for US - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for US - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for UY - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for UY - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for UY - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for UY - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for UZ - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for UZ - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for UZ - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for UZ - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for VA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for VA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for VA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for VA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for VC - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for VC - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for VC - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for VC - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for VE - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for VE - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for VE - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for VE - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for VN - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for VN - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for VN - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for VN - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for VU - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for VU - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for VU - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for VU - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for WF - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for WF - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for WF - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for WF - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Business Calling Meta passthrough fee - amount is determined by a rate deck (not flat). | Rate deck | minute | usage | — | — |
| WhatsApp Business Calling Telnyx platform fee - flat per call. | $0.0025 | call | usage | — | — |
| WhatsApp platform usage fee - charge is per message. | $0.004 | message | usage | — | — |
| WhatsApp Meta authentication fee for WS - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for WS - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for WS - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for WS - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for YE - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for YE - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for YE - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for YE - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for ZA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication international fee for ZA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for ZA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for ZA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for ZA - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for ZM - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for ZM - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for ZM - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for ZM - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta authentication fee for ZW - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta marketing fee for ZW - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta service fee for ZW - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |
| WhatsApp Meta utility fee for ZW - charge is per message - amount is determined by a rate deck (not flat). | Rate deck | message | usage | — | — |

### Wireless (`wireless`, 42 rates)

#### Global

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Rate to apply per MB via Reliance JIO in India | $0.01 | MB | usage | — | — |
| Rate to apply per MB when Plan-10 MB is overaged | $0.1 | MB | usage | — | — |
| Rate to apply per MB when Plan-100 MB is overaged | $0.8 | MB | usage | — | — |
| Rate to apply per MB when Plan-20 MB is overaged | $0.1 | MB | usage | — | — |
| Rate to apply per MB when Plan-20 GB is overaged | $0.06 | MB | usage | — | — |
| Rate to apply per MB when Plan-250 MB is overaged | $0.08 | MB | usage | — | — |
| Pay As You Go Data Allocation Wireless Plan- per amount of MB | $0.08 | plan | otc | — | — |
| Pay As You Go Data Allocation Wireless Plan- 10 MB | $1 | plan | mrc | — | — |
| Pay As You Go Data Allocation Wireless Plan- 100 MB | $10 | plan | mrc | — | — |
| Pay As You Go Data Allocation Wireless Plan- 20 MB | $2 | plan | mrc | — | — |
| Pay As You Go Data Allocation Wireless Plan- 2 GB | $120 | plan | mrc | — | — |
| Pay As You Go Data Allocation Wireless Plan- 250 MB | $20 | plan | mrc | — | — |
| Free Pay As You Go Data Allocation Wireless Plan | $0 | plan | otc | — | — |
| FREE Pay As You Go Data Allocation Wireless Plan- 10 MB | $0 | plan | mrc | — | — |
| Embedded MFF2 SIM card one time charge | $2.5 | sim_card | otc | — | — |
| Mobile Voice Usage Cost - amount is determined by a rate deck (not flat). | $0 | MB | usage | — | — |
| Wireless Portal Access Paywall Basic Monthly Recurring Charge | $200 | sim_card | mrc | — | — |
| Monthly recurring cost for private wireless gateway | $100 | gateway | mrc | — | — |
| SIM cards attached to a Private Wireless Gateway | $0 | sim_card | mrc | — | 100-1000: $0.6, 1000-3000: $0.54, 3000-5000: $0.48, 5000-10000: $0.36, 10000+: $0.3 |
| Wireless Tariffed Billing MRC | $0 | sim_card | mrc | — | — |
| Rate to apply per MB in zone 1 | $0.01 | MB | usage | — | — |
| Rate to apply per MB in zone 2 | $0.03 | MB | usage | — | — |
| Rate to apply per MB in zone 3 | $0.06 | MB | usage | — | — |
| Rate to apply per MB in zone 4 | $0.1 | MB | usage | — | — |
| Wireless Tiered Zone 1 Usage | $0.078 | MB | usage | — | 0-104857600: $0.078, 104857600-524288000: $0.039, 524288000-2147483648: $0.0195, 2147483648-5368709120: $0.015, 5368709120+: $0.0125 |
| Wireless Tiered Zone 2 Usage | $0.2028 | MB | usage | — | 0-104857600: $0.2028, 104857600-524288000: $0.1014, 524288000-2147483648: $0.0507, 2147483648-5368709120: $0.039, 5368709120+: $0.0325 |
| Wireless Tiered Zone 3 Usage | $0.39 | MB | usage | — | 0-104857600: $0.39, 104857600-524288000: $0.195, 524288000-2147483648: $0.0975, 2147483648-5368709120: $0.075, 5368709120+: $0.0625 |
| Wireless Tiered Zone 4 Usage | $0.78 | MB | usage | — | 0-104857600: $0.78, 104857600-524288000: $0.39, 524288000-2147483648: $0.195, 2147483648-5368709120: $0.15, 5368709120+: $0.125 |
| Wireless Tiered Zone 5 Usage | $2.028 | MB | usage | — | 0-104857600: $2.028, 104857600-524288000: $1.014, 524288000-2147483648: $0.507, 2147483648-5368709120: $0.39, 5368709120+: $0.325 |
| Wireless Tiered Zone 6 Usage | $3.9 | MB | usage | — | 0-104857600: $3.9, 104857600-524288000: $1.95, 524288000-2147483648: $0.975, 2147483648-5368709120: $0.75, 5368709120+: $0.625 |
| Wireless Tiered Zone 7 Usage | $7.8 | MB | usage | — | 0-104857600: $7.8, 104857600-524288000: $3.9, 524288000-2147483648: $1.95, 2147483648-5368709120: $1.5, 5368709120+: $1.25 |
| Wireless Tiered Zone 8 Usage | $20.28 | MB | usage | — | 0-104857600: $20.28, 104857600-524288000: $10.14, 524288000-2147483648: $5.07, 2147483648-5368709120: $3.9, 5368709120+: $3.25 |
| Wireless Tiered Zone 9 Usage | $39 | MB | usage | — | 0-104857600: $39, 104857600-524288000: $19.5, 524288000-2147483648: $9.75, 2147483648-5368709120: $7.5, 5368709120+: $6.25 |
| Wireless Tiered Canada and other Zone 1 Usage per MB | $0.0125 | MB | usage | — | — |
| Wireless Tiered Colombia only Usage per MB | $0.04 | MB | usage | — | — |
| Wireless Tiered EU only Usage per MB | $0.005 | MB | usage | — | — |
| Wireless Tiered Zone JIO Usage per MB | $0.078 | MB | usage | — | 0-104857600: $0.078, 104857600-524288000: $0.039, 524288000-2147483648: $0.0195, 2147483648-5368709120: $0.015, 5368709120+: $0.0125 |
| Wireless Tiered Zone T-Mobile US Usage per MB | $0.01 | MB | usage | — | — |
| Wireless Tiered US only Usage per MB | $0.0065 | MB | usage | — | — |

#### US

| Item | Rate | Unit | Type | Direction | Volume tiers |
|---|---:|---|---|---|---|
| Rate to apply per MB via AT&T in the US | $0.01 | MB | usage | — | — |
| Rate to apply per MB via T-Mobile in the US | $0.01 | MB | usage | — | — |
| Mobile Voice Monthly Recurring Charge | $5 | sim_card | mrc | — | — |
