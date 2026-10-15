---
name: webhooks
description: Use this skill when consuming RevenueCat webhooks on your backend. Covers the normalized event schema, the access changing event types, idempotency via the event id field, cancel_reason branching on CANCELLATION, and the correct handling for CANCELLATION versus EXPIRATION versus RENEWAL.
license: Apache-2.0; see LICENSE
metadata:
  author: RevenueCat
  source: revenuecat-handbook chapter 10
  keywords:
  - android
  - revenuecat
  - webhooks
  - event-types
  - idempotency
  - cancellation
  - expiration
---

# RevenueCat Webhooks

You configure one endpoint. RevenueCat posts one normalized JSON event schema for every store. Your job on the server side is to verify the signature, deduplicate by `event.id`, and dispatch per event type.

## Phase 1: Discover

Confirm what you are wiring up before touching code.

- You own a server side HTTPS endpoint that accepts POST with a JSON body.
- You have the webhook secret from the RevenueCat dashboard under Integrations then Webhooks.
- You have durable storage to record processed event IDs and entitlement state per `app_user_id`.
- You understand that RevenueCat has already mapped products to entitlements, so you branch on `event.type` and read `event.entitlement_ids`. You do not maintain a product to entitlement table on your backend.

Every event has this outer shape:

```json
{
  "api_version": "1.0",
  "event": {
    "id": "evt_01HABCXYZ0000000000000001",
    "type": "INITIAL_PURCHASE",
    "app_user_id": "user_12345",
    "product_id": "premium_monthly",
    "period_type": "NORMAL",
    "purchased_at_ms": 1700000000000,
    "expiration_at_ms": 1702592000000,
    "store": "PLAY_STORE",
    "environment": "PRODUCTION",
    "entitlement_ids": ["pro_access"],
    "transaction_id": "GPA.1234-5678-9012-34567"
  }
}
```

## Phase 2: Plan

Pick the right action for each event type before you write the handler.

| Event type | Meaning | Handler action |
|---|---|---|
| `INITIAL_PURCHASE` | First paid transaction for this user and product. | Grant entitlements in `entitlement_ids`. |
| `RENEWAL` | Subscription renewed, including resubscription after an `EXPIRATION`. | Grant or extend entitlements in `entitlement_ids`. |
| `NON_RENEWING_PURCHASE` | A one time or lifetime purchase (never auto renews). | Grant entitlements in `entitlement_ids`. Null `expiration_at_ms` means lifetime. |
| `CANCELLATION` | Auto renew turned off, a billing issue was detected, or a refund. Read `cancel_reason`. | `UNSUBSCRIBE`, `DEVELOPER_INITIATED`, `PRICE_INCREASE`: schedule revocation at `expiration_at_ms`. `BILLING_ERROR`: no access change (wait for `RENEWAL` or `EXPIRATION`). `CUSTOMER_SUPPORT` (refund): revoke now. |
| `UNCANCELLATION` | User re enabled auto renew before expiry. | Cancel any scheduled revocation. Keep entitlements active. |
| `EXPIRATION` | Subscription actually ended. | Revoke entitlements now. |
| `BILLING_ISSUE` | Payment failed. User may be in grace period or on hold. | Flag the account. Do not revoke yet. RevenueCat sends `EXPIRATION` if recovery fails. |
| `SUBSCRIPTION_EXTENDED` | Expiry pushed back through the store API (for example a defer). | Update the stored expiry to `expiration_at_ms` and reschedule any pending revocation. |
| `SUBSCRIPTION_PAUSED` | Google Play subscription scheduled to pause. | No access change yet. Access ends later with `EXPIRATION` (`expiration_reason` `SUBSCRIPTION_PAUSED`). |
| `TEMPORARY_ENTITLEMENT_GRANT` | Short lived outage grant (up to 24h). Carries only `app_user_id` and `store`. | No `entitlement_ids` or expiry in the payload: re-read `GET /v1/subscribers/{app_user_id}`, or act on the `INITIAL_PURCHASE` or `EXPIRATION` that follows. |
| `PRODUCT_CHANGE` | User switched plan (upgrade, downgrade, or cross grade). | When `new_product_id` is present (a deferred Google Play change), `product_id` is the old product. The change takes effect at the next renewal date, when RevenueCat sends `INITIAL_PURCHASE` for the new product (`RENEWAL` on App Store and Stripe): record the change as pending and apply it on that event. Otherwise update the product on record. Entitlement state follows `entitlement_ids`. |
| `TRANSFER` | Purchases moved from one app user ID to another. | Revoke entitlements for `transferred_from`, grant for `transferred_to`. No `app_user_id` on this event. |
| `SUBSCRIBER_ALIAS` | Deprecated. Two app user IDs were merged into one identity. | Legacy projects only: merge your local records for the aliased IDs. New projects don't receive this event. |

Key decisions baked into this table:

- `CANCELLATION` is usually an intent signal, not an access change: for `UNSUBSCRIBE`, `DEVELOPER_INITIATED`, and `PRICE_INCREASE`, revoking now is a bug that deletes paid access the user still owns. For `CUSTOMER_SUPPORT` (a refund) revoke immediately. For `BILLING_ERROR` do not revoke; RevenueCat already sent `BILLING_ISSUE` and will send `RENEWAL` on recovery or `EXPIRATION` if it fails. Always branch on `cancel_reason`.
- `EXPIRATION` is the access change for everything except a refund. This is when you revoke.
- Resubscription after an `EXPIRATION` fires `RENEWAL`, not `INITIAL_PURCHASE`. Your `RENEWAL` branch must be safe to run against a user whose entitlements are currently revoked, which means it must grant, not just extend.
- `BILLING_ISSUE` is not revocation. Revoking on `BILLING_ISSUE`, or on the `CANCELLATION` with `cancel_reason` `BILLING_ERROR` that fires alongside it, cuts off users who are still inside a Google Play grace period. Users in account hold already lost access through the `EXPIRATION` that RevenueCat sends when grace ends.

## Phase 3: Execute

Wire up a handler that verifies, deduplicates, and dispatches.

### Verify the signature and parse

```kotlin
post("/revenuecat/webhook") {
    val body = call.receiveText()
    val header = call.request.headers["X-RevenueCat-Webhook-Signature"] // only if HMAC signing is enabled
    if (header == null || !verifySignature(body, header, signingSecret)) {
        call.respond(HttpStatusCode.Unauthorized); return@post
    }
    // verifySignature: parse t and v1, compute hex HMAC-SHA256(secret, "$t.$body") over the raw body,
    // constant time compare with v1, reject when |now - t| > 300 s.
    val event = Json.decodeFromString<RevenueCatEnvelope>(body).event
    handleEvent(event)
    call.respond(HttpStatusCode.OK)
}
```

If your dashboard has HMAC signing enabled, verify `X-RevenueCat-Webhook-Signature` as above. If not, verify the `Authorization` header value you configured in the RevenueCat dashboard instead.

Return 200 as soon as the event is persisted, within 60 seconds. If processing is slow, enqueue it and acknowledge. A slow handler causes retries and duplicate deliveries.

### Deduplicate on event.id

RevenueCat can redeliver the same event. `event.id` is the idempotency key.

```kotlin
suspend fun handleEvent(event: RcEvent) {
    if (processedEvents.insertIfAbsent(event.id)) {
        dispatch(event)
    }
    // Already processed: fall through, responder still returns 200.
}
```

`insertIfAbsent` must be atomic in your store (a unique index on `event_id` plus an insert that swallows duplicate key errors works). Do all downstream writes in the same transaction as the event ID insert so a crash mid handler does not leave you with a marked but unapplied event.

### Dispatch per type

```kotlin
suspend fun dispatch(e: RcEvent) = when (e.type) {
    "INITIAL_PURCHASE", "RENEWAL", "UNCANCELLATION", "NON_RENEWING_PURCHASE" ->
        db.grantEntitlements(e.appUserId, e.entitlementIds, e.expirationAtMs)
    "CANCELLATION" -> when (e.cancelReason) {
        "CUSTOMER_SUPPORT" -> db.revokeEntitlements(e.appUserId, e.entitlementIds)
        "BILLING_ERROR" -> Unit // BILLING_ISSUE already flagged it; wait for RENEWAL or EXPIRATION
        else -> db.scheduleRevocation(e.appUserId, e.entitlementIds, e.expirationAtMs)
    }
    "EXPIRATION" ->
        db.revokeEntitlements(e.appUserId, e.entitlementIds)
    "SUBSCRIPTION_EXTENDED" ->
        db.rescheduleRevocation(e.appUserId, e.entitlementIds, e.expirationAtMs)
    "BILLING_ISSUE" ->
        db.flagBillingIssue(e.appUserId)
    "SUBSCRIPTION_PAUSED" ->
        Unit // no access change; access ends with a later EXPIRATION
    "TEMPORARY_ENTITLEMENT_GRANT" ->
        db.refreshFromRest(e.appUserId) // payload has no entitlement_ids or expiration_at_ms
    "PRODUCT_CHANGE" ->
        if (e.newProductId != null) {
            db.recordPendingProductChange(e.appUserId, e.newProductId) // deferred; takes effect with the INITIAL_PURCHASE for the new product
        } else {
            db.updateProduct(e.appUserId, e.productId, e.entitlementIds)
        }
    "TRANSFER" ->
        db.transfer(from = e.transferredFrom, to = e.transferredTo)
    "SUBSCRIBER_ALIAS" ->
        db.mergeIdentity(e) // legacy projects only; new projects don't receive this event
    else -> Unit
}
```

Notes that match the handbook:

- `grantEntitlements` on `RENEWAL` must be idempotent and additive so a resubscribe after `EXPIRATION` restores access.
- `scheduleRevocation` stores a pending job keyed by `(app_user_id, entitlement_id)` that fires at `expiration_at_ms`. `RENEWAL`, `UNCANCELLATION`, `PRODUCT_CHANGE`, and `SUBSCRIPTION_EXTENDED` cancel or reschedule the job. If an `EXPIRATION` arrives first, let the `EXPIRATION` handler revoke and drop the pending job. Safer: when the job fires, re-read `GET /v1/subscribers/{app_user_id}` and revoke only if the entitlement's `expires_date` has passed.

### CANCELLATION payload (UNSUBSCRIBE, access continues)

```json
{
  "api_version": "1.0",
  "event": {
    "id": "evt_01HABCXYZ0000000000000010",
    "type": "CANCELLATION",
    "app_user_id": "user_12345",
    "product_id": "premium_monthly",
    "purchased_at_ms": 1700000000000,
    "expiration_at_ms": 1702592000000,
    "cancel_reason": "UNSUBSCRIBE",
    "entitlement_ids": ["pro_access"],
    "store": "PLAY_STORE",
    "environment": "PRODUCTION"
  }
}
```

The user keeps `pro_access` until `1702592000000`. Schedule revocation for that timestamp. A `cancel_reason` of `BILLING_ERROR` or `CUSTOMER_SUPPORT` needs different handling; see the Phase 2 table.

### EXPIRATION payload (revoke now)

```json
{
  "api_version": "1.0",
  "event": {
    "id": "evt_01HABCXYZ0000000000000011",
    "type": "EXPIRATION",
    "app_user_id": "user_12345",
    "product_id": "premium_monthly",
    "expiration_at_ms": 1702592000000,
    "entitlement_ids": ["pro_access"],
    "store": "PLAY_STORE",
    "environment": "PRODUCTION"
  }
}
```

Revoke `pro_access` for `user_12345` as soon as you process this.

### RENEWAL after expiry (resubscription)

When a lapsed user resubscribes, RevenueCat sends `RENEWAL`, not `INITIAL_PURCHASE`.

```json
{
  "api_version": "1.0",
  "event": {
    "id": "evt_01HABCXYZ0000000000000012",
    "type": "RENEWAL",
    "app_user_id": "user_12345",
    "product_id": "premium_monthly",
    "purchased_at_ms": 1705270400000,
    "expiration_at_ms": 1707862400000,
    "entitlement_ids": ["pro_access"],
    "store": "PLAY_STORE",
    "environment": "PRODUCTION"
  }
}
```

Your `RENEWAL` branch must grant entitlements, not assume they already exist. If you only extend an existing expiry, the resubscribed user stays locked out.

## Verification Checklist

- Signature verification rejects requests with missing or wrong `X-RevenueCat-Webhook-Signature` (or `Authorization`, when HMAC signing is off).
- A replayed event with the same `event.id` is a no op and still returns 200.
- `CANCELLATION` branches on `cancel_reason`: `UNSUBSCRIBE`/`DEVELOPER_INITIATED`/`PRICE_INCREASE` retain entitlements until `expiration_at_ms`; `CUSTOMER_SUPPORT` revokes now; `BILLING_ERROR` makes no access change.
- `EXPIRATION` revokes access for the IDs in `entitlement_ids`.
- A `RENEWAL` arriving after an `EXPIRATION` restores access for the same `app_user_id`.
- `BILLING_ISSUE` flags the account without revoking.
- `NON_RENEWING_PURCHASE` grants access the same as `INITIAL_PURCHASE`; `TEMPORARY_ENTITLEMENT_GRANT` is never read for `entitlement_ids` (its payload has none).
- `SUBSCRIPTION_EXTENDED` updates the stored expiry; `TRANSFER` revokes `transferred_from` and grants `transferred_to`.
- Handler returns 200 within 60 seconds even when downstream work is async.

## References

- [Full chapter](https://www.revenuecat.com/guides/revenuecat-android-sdk/webhooks)
