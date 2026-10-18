# OrderDesk workflows

OrderDesk demonstrates how a host application owns business behavior while
Parlora coordinates voice sessions. The catalog contains fictional orders
123, 124, and 825. See [setup and launch commands](README.md).

## Lookups and corrections

Ask for an order's status, items, or delivery instructions. The application
interprets the caller's request, authorizes the operation for its demonstration
customer, and submits it through the selected backend.

Correcting an order number creates a new task revision. Parlora suppresses stale
results before delivery to the voice provider. A clarification is needed when the
application cannot confidently determine a new operation or target. Presence
checks and continuation questions can retain the existing order context.

Interpretation uses TypeSafe for intent and reference classification plus bounded
application parsing for literal order numbers and delivery text. These decisions
are application policy; they are not built into Parlora's adapters. The terminal
runner uses a smaller deterministic policy.

## Delivery changes require browser confirmation

Voice creates a draft with an exact order, delivery text, owner, expected record
version, and five-minute expiry. Spoken approval does not invoke a save. Review
the displayed draft and use the browser confirmation action.

Confirmation checks ownership, pending state, expiry, and current order version,
then updates the order and records the outcome in one transaction. Retrying the
same proposal ID returns its existing outcome rather than applying the write twice.
Expired, rejected, or conflicting drafts cannot change an order.

A recognized spoken refusal rejects the call's associated draft without changing
saved instructions. A correction can create a new draft; review any older pending
drafts separately. A saved change is not undone by interruption, cancellation,
or later conversation.

## What owns what

| Component | Responsibility |
| --- | --- |
| Parlora | Audio channels, provider connections, session lifecycle, revision checks |
| Application policy and interpretation | Intent, order selection, clarification, task decisions |
| Backend operations | Authorized reads and creation of delivery drafts |
| SQLite store | Orders, proposal state, version checks, atomic change history |
| Browser confirmation route | Explicit authorization of the displayed write |
| Browser/phone servers | Listener, identity, Origin/CSRF checks, admission, duration |

Jido, Sagents, and Legion call the same application operations. The voice model
and backend text model cannot bypass browser confirmation to persist a change.
TypeSafe and SQLite are dependencies of this example, not requirements for a
Parlora application.

## Persistence and identity

SQLite uses WAL, `synchronous=FULL`, bound parameters, and one owning process.
Orders are seeded only when absent. `ORDER_DESK_DATABASE` selects the file;
startup retains saved records. Parlora sessions themselves remain in memory.

The local example has no account login. Signed cookies distinguish browser owners;
mutations require the expected Origin and CSRF token. Restart rotates the cookie
signing key, so old pending drafts lose their browser association and expire.
Saved orders and history persist. Phone calls use a demonstration actor rather
than treating caller ID as customer authentication.

Before adapting the example for public use, replace demonstration identity with
your application's authentication and authorization, deploy HTTPS, and configure
call admission and network connectivity for the intended environment.
