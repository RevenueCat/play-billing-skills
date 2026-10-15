---
name: webhooks
description: Use this skill when consuming RevenueCat webhooks on your backend. Covers the normalized event schema, the full event type list, idempotency via the event id field, and the correct handling for CANCELLATION versus EXPIRATION versus RENEWAL.
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

You configure one endpoint. RevenueCat posts one normalized JSON event schema for every store. Your job on the server side is to authenticate the request, deduplicate by `event.id`, and dispatch per event type.

## Phase 1: Discover

Confirm what you are wiring up before touching code.

- You own a server side HTTPS endpoint that accepts POST with a JSON body.
- You set an authorization header value on the webhook integration in the RevenueCat dashboard under Integrations then Webhooks. If you also turn on HMAC webhook signing there, you have its signing secret.
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
| `INITIAL_PURCHASE` | A new subscription started, including a free trial (`price` is 0). | Grant entitlements in `entitlement_ids`. |
| `NON_RENEWING_PURCHASE` | A purchase that won't auto renew, such as a one time product. | Grant `entitlement_ids` if the product maps to any, and credit consumables by `product_id`. |
| `RENEWAL` | Subscription renewed, including resubscription after an `EXPIRATION`. | Grant or extend entitlements in `entitlement_ids`. |
| `CANCELLATION` | Auto renew was turned off, a renewal charge failed (`cancel_reason` is `BILLING_ERROR`), or the purchase was refunded (`CUSTOMER_SUPPORT`). | Re-read the customer and apply its current access. Reverse any consumable credit recorded for that `transaction_id`. |
| `UNCANCELLATION` | User re enabled auto renew before expiry. | Keep entitlements active. |
| `EXPIRATION` | Subscription actually ended. | Revoke entitlements now. |
| `BILLING_ISSUE` | Payment failed. User may be in grace period or on hold. | Flag the account. Do not revoke yet. RevenueCat sends `EXPIRATION` if recovery fails. |
| `PRODUCT_CHANGE` | User switched plan (upgrade, downgrade, or cross grade). | Update the product on record. Entitlement state follows `entitlement_ids`. |
| `SUBSCRIBER_ALIAS` | Deprecated. New projects don't receive it. In legacy projects, a new app user ID was registered for an existing customer. | Merge your local records for the aliased IDs. |
| `TRANSFER` | Purchases and entitlements moved from the IDs in `transferred_from` to the IDs in `transferred_to`. The event has no `app_user_id`. | Move entitlements from `transferred_from` to `transferred_to`. Do not merge the two users. |
| `SUBSCRIPTION_PAUSED` | Google Play only. The subscription will pause at the end of the current period. `auto_resume_at_ms` says when it resumes. | Do not revoke. Revoke on the later `EXPIRATION` whose `expiration_reason` is `SUBSCRIPTION_PAUSED`. |
| `SUBSCRIPTION_EXTENDED` | The current period's expiration was pushed back, for example through the store's API. On Google Play it can also mean Google deferred a renewal charge by less than 24 hours. | Re-read the customer and apply the new expiration. |
| `TEMPORARY_ENTITLEMENT_GRANT` | RevenueCat granted short term access (at most 24 hours) because a store could not validate a purchase. Carries the common fields and `app_user_id`, sometimes `store`, and no entitlement or expiration fields. | Re-read the customer to apply the grant. Expect `INITIAL_PURCHASE` or `EXPIRATION` later. |
| `REFUND_REVERSED` | App Store only. A refund was reversed. | Re-read the customer and restore access. |
| `PRICE_INCREASE_CONSENT_REQUIRED`, `PRICE_INCREASE_CONSENT_APPROVED` | A price increase needs, or got, the customer's consent before the subscription renews at the new price. | No access change. |
| `VIRTUAL_CURRENCY_TRANSACTION` | A virtual currency balance changed. `source` says why: an in app purchase, an admin or server API call, the client SDK, an expiration, or an ad reward. | Update balances if you mirror them. No entitlement change. |
| `INVOICE_ISSUANCE` | RevenueCat Billing only. An unpaid invoice was issued. | No access change. |
| `EXPERIMENT_ENROLLMENT` | The customer was enrolled in an experiment. | No access change. |
| `PURCHASE_REDEEMED` | A web purchase (Stripe, Paddle, or RevenueCat Billing) was redeemed in the app. `redemption_outcome` says how: `transfer` also sends `TRANSFER`, `alias` links the redeemer IDs in `redeemed_by` to the purchaser without a `TRANSFER`, and `redeemer_owns` changes nothing. | Re-read each customer in `redeemed_by`, so an alias redemption grants access in your records. |
| `TEST` | A test event sent from the dashboard. | Return 200 and change nothing. |

When an event carries less than you need, re-read the customer with `GET /v1/subscribers/{app_user_id}`. RevenueCat recommends this after any webhook.

Key decisions baked into this table:

- A `CANCELLATION` does not say whether access ended, so read it from RevenueCat instead of deciding from `cancel_reason`. After an unsubscribe the user keeps access until `expiration_at_ms`, so revoking now deletes paid access the user still owns. After a billing error, access depends on the store and its grace period. After a refund, access usually ends now.
- `EXPIRATION` is the access change. This is when you revoke.
- Resubscription after an `EXPIRATION` fires `RENEWAL`, not `INITIAL_PURCHASE`. Your `RENEWAL` branch must be safe to run against a user whose entitlements are currently revoked, which means it must grant, not just extend.
- `BILLING_ISSUE` is not revocation. Revoking on `BILLING_ISSUE` cuts off users who are still inside Google Play grace period or account hold.

## Phase 3: Execute

Wire up a handler that verifies, deduplicates, and dispatches.

### Authenticate and parse

RevenueCat sends the authorization header value you set on the webhook integration with every request. HMAC signing is optional. When it is on, each delivery also carries `X-RevenueCat-Webhook-Signature: t=<unix_timestamp>,v1=<hmac_sha256_hex>`, an HMAC-SHA256 of `"<t>.<raw body>"` keyed with the integration's signing secret. RevenueCat recomputes `t` and `v1` on every delivery attempt, retries included.

```kotlin
// Fail at startup on a missing or blank value. A blank one would match an empty Authorization header.
val expectedAuthorization: String = System.getenv("RC_WEBHOOK_AUTHORIZATION")?.takeIf { it.isNotBlank() }
    ?: error("Set RC_WEBHOOK_AUTHORIZATION to the authorization header value from the RevenueCat dashboard")

post("/revenuecat/webhook") {
    if (!constantTimeEquals(call.request.headers[HttpHeaders.Authorization], expectedAuthorization)) {
        call.respond(HttpStatusCode.Unauthorized); return@post
    }
    // Keep the raw bytes: the HMAC covers them exactly as received, so parse JSON only after verifying.
    val body = call.receive<ByteArray>()
    if (hmacSigningEnabled &&
        !verifyHmac(body, call.request.headers["X-RevenueCat-Webhook-Signature"], signingSecret)
    ) {
        call.respond(HttpStatusCode.Unauthorized); return@post
    }
    val event = webhookJson.decodeFromString<RevenueCatEnvelope>(body.decodeToString()).event
    handleEvent(event)
    call.respond(HttpStatusCode.OK)
}

fun constantTimeEquals(actual: String?, expected: String): Boolean =
    actual != null && MessageDigest.isEqual(actual.toByteArray(), expected.toByteArray())

fun verifyHmac(body: ByteArray, header: String?, secret: String, toleranceSeconds: Long = 300): Boolean {
    val parts = header?.split(",")?.associate { it.substringBefore("=") to it.substringAfter("=") }
        ?: return false
    val t = parts["t"] ?: return false
    val v1 = parts["v1"] ?: return false
    val timestamp = t.toLongOrNull() ?: return false
    val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(secret.toByteArray(), "HmacSHA256")) }
    val expected = mac.doFinal("$t.".toByteArray() + body).joinToString("") { "%02x".format(it) }
    return MessageDigest.isEqual(expected.toByteArray(), v1.toByteArray()) &&
        abs(System.currentTimeMillis() / 1000 - timestamp) <= toleranceSeconds
}

// RevenueCat adds payload fields over time, so ignore the ones you do not model.
// A field the docs mark Always can still be null, so a null list falls back to its empty default.
val webhookJson = Json { ignoreUnknownKeys = true; coerceInputValues = true }
```

`t` is when RevenueCat signed that HTTP request, so the five minute tolerance only needs to cover clock skew and request latency, not retry delays.

When signing is on, load `signingSecret` the same way. A missing or blank value must never turn into an open endpoint.

Return 200 as soon as the event is persisted. RevenueCat treats any other status code as a failure and retries. If processing is slow, enqueue it and acknowledge. A slow handler causes retries and duplicate deliveries.

### Model only the fields you use

Event types carry different fields. `TRANSFER` and `PURCHASE_REDEEMED` have no `app_user_id`, and `entitlement_ids` and `expiration_at_ms` can be `null`, so keep those fields nullable.

```kotlin
@Serializable
data class RevenueCatEnvelope(val event: RcEvent)

@Serializable
data class RcEvent(
    val id: String,
    val type: String,
    @SerialName("app_user_id") val appUserId: String? = null,
    @SerialName("product_id") val productId: String? = null,
    @SerialName("transaction_id") val transactionId: String? = null,
    @SerialName("entitlement_ids") val entitlementIds: List<String>? = null,
    @SerialName("expiration_at_ms") val expirationAtMs: Long? = null,
    @SerialName("transferred_from") val transferredFrom: List<String> = emptyList(),
    @SerialName("transferred_to") val transferredTo: List<String> = emptyList(),
    @SerialName("redeemed_by") val redeemedBy: List<String> = emptyList(),
)
```

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
    "INITIAL_PURCHASE", "RENEWAL", "UNCANCELLATION" ->
        db.grantEntitlements(e.appUserId, e.entitlementIds, e.expirationAtMs)
    "NON_RENEWING_PURCHASE" ->
        db.recordOneTimePurchase(e.appUserId, e.productId, e.transactionId, e.entitlementIds)
    "CANCELLATION" -> {
        db.syncFromRevenueCat(e.appUserId) // re-read GET /v1/subscribers/{app_user_id}
        db.reverseOneTimePurchase(e.transactionId) // a cancelled one time purchase was refunded or revoked; no-op otherwise
    }
    "EXPIRATION" ->
        db.revokeEntitlements(e.appUserId, e.entitlementIds)
    "BILLING_ISSUE" ->
        db.flagBillingIssue(e.appUserId)
    "PRODUCT_CHANGE" ->
        db.updateProduct(e.appUserId, e.productId, e.entitlementIds)
    "SUBSCRIBER_ALIAS" ->
        db.mergeIdentity(e)
    "TRANSFER" ->
        db.moveEntitlements(from = e.transferredFrom, to = e.transferredTo)
    "SUBSCRIPTION_EXTENDED", "TEMPORARY_ENTITLEMENT_GRANT", "REFUND_REVERSED" ->
        db.syncFromRevenueCat(e.appUserId) // re-read GET /v1/subscribers/{app_user_id}
    "PURCHASE_REDEEMED" ->
        e.redeemedBy.forEach { db.syncFromRevenueCat(it) }
    else -> Unit // SUBSCRIPTION_PAUSED, TEST, and the other events that change no access
}
```

Notes:

- `grantEntitlements` on `RENEWAL` must be idempotent and additive so a resubscribe after `EXPIRATION` restores access.
- `CANCELLATION` re-reads the customer instead of scheduling a revocation at `expiration_at_ms`. A scheduled job would have to be cancelled by every `RENEWAL` and `UNCANCELLATION`, and `EXPIRATION` already revokes when access ends.

### CANCELLATION payload (access continues)

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
    "entitlement_ids": ["pro_access"],
    "cancel_reason": "UNSUBSCRIBE",
    "store": "PLAY_STORE",
    "environment": "PRODUCTION"
  }
}
```

The user keeps `pro_access` until `1702592000000`, so the re-read still shows it active. The `EXPIRATION` sent at that time revokes it.

A refund looks the same except `cancel_reason` is `CUSTOMER_SUPPORT`. Access usually ends now, so re-read the customer and apply what RevenueCat returns. Some refunds keep access, for example a Stripe refund issued without revoking. Auto renew can stay on after a refund, so a later `RENEWAL` may grant access again. For a one time purchase, also reverse the credit you recorded for its `transaction_id`.

With `cancel_reason` `BILLING_ERROR`, a renewal charge failed. With a grace period the user keeps access and `EXPIRATION` arrives if it ends without recovery, while a Stripe subscription set to cancel on failed payment loses access right away. The re-read covers both.

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

- Requests without the expected `Authorization` header get 401. With HMAC signing on, a missing, stale, or wrong `X-RevenueCat-Webhook-Signature` gets 401 too.
- A replayed event with the same `event.id` is a no op and still returns 200.
- A `NON_RENEWING_PURCHASE` provisions the one time product. One time purchases never arrive as `INITIAL_PURCHASE`.
- A `CANCELLATION` re-reads the customer instead of revoking. After an unsubscribe the user keeps entitlements until the `EXPIRATION`, and a refunded one time purchase has its consumable credit reversed.
- A `TRANSFER` moves entitlements from `transferred_from` to `transferred_to` and keeps the two users separate.
- `EXPIRATION` revokes access for the IDs in `entitlement_ids`.
- A `RENEWAL` arriving after an `EXPIRATION` restores access for the same `app_user_id`.
- `BILLING_ISSUE` flags the account without revoking.
- `SUBSCRIPTION_PAUSED` keeps access. The `EXPIRATION` with `expiration_reason` `SUBSCRIPTION_PAUSED` revokes it.
- Handler returns 200 within your retry window even when downstream work is async. RevenueCat treats any other status as a failure.

## References

- [Full chapter](https://www.revenuecat.com/guides/revenuecat-android-sdk/webhooks)
