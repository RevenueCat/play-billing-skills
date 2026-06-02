---
name: rtdn
description: Use this skill when setting up Real Time Developer Notifications (RTDN) for Google Play. Covers the full pipeline from Cloud Pub/Sub configuration through message parsing and processing all 22 subscription notification types (renewals, cancellations, revocations, account holds, etc.).
license: Apache-2.0; see LICENSE
metadata:
  author: RevenueCat
  source: google-play-handbook chapter 10
  keywords:
  - android
  - play-billing
  - rtdn
  - cloud-pubsub
  - webhooks
  - notification-types
---

# Real Time Developer Notifications (RTDN)

RTDN pushes subscription and purchase state changes from Google Play to your backend within seconds. Use it as the primary signal for entitlement updates; polling the Play Developer API on a schedule is a fallback, not a substitute.

## Phase 1: Understand

Pin down the following before you write code:

- **What triggers a notification.** Google Play publishes a message to a Cloud Pub/Sub topic you own every time a subscription or one time product changes state (renewal, cancellation, refund, hold, pause, revocation, price change confirmation, etc.).
- **What the notification contains.** A `DeveloperNotification` JSON object with `packageName`, `eventTimeMillis`, and exactly one of `subscriptionNotification`, `oneTimeProductNotification`, `voidedPurchaseNotification`, or `testNotification`. It carries a `purchaseToken` and a type code, not the full purchase state.
- **Who owns what.** You own the Pub/Sub topic and subscription in your own Google Cloud project. Google Play only has publish rights.
- **Delivery semantics.** Cloud Pub/Sub guarantees at least once delivery and does not guarantee ordering. Duplicates and out of order messages are normal.
- **The golden rule.** RTDNs are signals, not sources of truth. For every notification, call `purchases.subscriptionsv2.get` or `purchases.products.get` and update entitlements from the API response, not the notification type.

Decide push vs pull:

| Strategy | Pick when |
|----------|-----------|
| Push subscription | You have a public HTTPS endpoint and want a webhook style integration with retries handled by Pub/Sub |
| Pull subscription | Your backend has no public URL, needs batch processing, or wants fine grained control over consumption rate |

Push is the simpler default. You can swap strategies later without changing the Play Console configuration.

## Phase 2: Plan

Write the plan before provisioning anything.

### Infrastructure checklist

- One Pub/Sub topic (example: `play-billing-notifications`). One topic handles subscriptions, one time products, and voided purchases.
- One subscription attached to the topic with an appropriate `ack-deadline` (60s is a reasonable starting point).
- IAM binding granting `roles/pubsub.publisher` to `google-play-developer-notifications@system.gserviceaccount.com` on the topic.
- Play Console Monetization setup pointing at `projects/YOUR_PROJECT_ID/topics/play-billing-notifications`.
- A test notification fired from the Play Console to confirm end to end wiring.

### Ack semantics

Your webhook must return `2xx` within the ack deadline to acknowledge the message. Any other response or a timeout causes Pub/Sub to retry with exponential backoff. Plan accordingly:

- Ack as soon as you have durably captured the message (message ID plus payload). Do the API call and database updates inside the same request only if they fit well inside the ack deadline. Otherwise ack fast and process asynchronously from a queue you own.
- Never ack before you have persisted enough to replay the work. A lost message after ack means a missed state change.
- A `5xx` response forces Pub/Sub to resend, which you want for transient failures. A `4xx` response signals a permanent error and may drop the message (or send it to a dead letter topic if configured). Pick the status code deliberately.

### Idempotency plan

Because duplicates and out of order deliveries are guaranteed, every handler must be idempotent.

- **Deduplicate on Pub/Sub `messageId`.** Persist processed message IDs with a TTL of 24 to 48 hours. Skip any replay you have already seen, then ack.
- **Do not mutate state from the notification type alone.** Always call the Developer API for the current state. Two out of order notifications produce two API calls that both return the same current state, so your database converges to the correct value.
- **Track `eventTimeMillis` per `purchaseToken`.** Record the highest event time you have seen so you can detect stale events if you need to branch logic, but still call the API on every notification.
- **Make database writes idempotent.** Use upserts keyed on `purchaseToken` rather than inserts. Revoking access must be safe to run twice; so must extending expiry.

### Monitoring

- Dashboard the count of unacked messages and the oldest unacked age on the subscription.
- Alert on sustained non 2xx responses from the webhook.
- Count notifications by type as a metric so you can spot anomalies (for example, a spike in `SUBSCRIPTION_ON_HOLD`).

## Phase 3: Execute

### Step 1: Create the topic

```bash
gcloud pubsub topics create play-billing-notifications
```

### Step 2: Grant publish rights to Google Play

```bash
gcloud pubsub topics add-iam-policy-binding \
  play-billing-notifications \
  --member=serviceAccount:google-play-developer-notifications@system.gserviceaccount.com \
  --role=roles/pubsub.publisher
```

Missing this binding is the most common reason a freshly configured RTDN pipeline delivers no messages.

### Step 3: Create a push subscription

```bash
gcloud pubsub subscriptions create play-billing-sub \
  --topic=play-billing-notifications \
  --push-endpoint=https://api.yourapp.com/billing/rtdn \
  --ack-deadline=60
```

For pull, omit `--push-endpoint` and run a subscriber loop in your backend.

### Step 4: Enable RTDN in Play Console

In the Play Console, open Monetization setup, find Real time developer notifications, enter `projects/YOUR_PROJECT_ID/topics/play-billing-notifications`, click Send test notification, and save. A push subscriber should receive the test within seconds.

### Step 5: Write the webhook endpoint

The push body wraps the notification in a Pub/Sub envelope. The `data` field is a base64 encoded JSON string.

```json
{
  "message": {
    "data": "eyJ2ZXJzaW9uIjoiMS4wIiwi...",
    "messageId": "136969346945",
    "attributes": {}
  },
  "subscription": "projects/myproject/subscriptions/play-billing-sub"
}
```

Decode the payload:

```kotlin
import java.util.Base64

fun decodePubSubData(base64: String): String {
    val bytes = Base64.getDecoder().decode(base64)
    return String(bytes, Charsets.UTF_8)
}
```

Parse into a `DeveloperNotification`:

```kotlin
data class DeveloperNotification(
    val version: String,
    val packageName: String,
    val eventTimeMillis: Long,
    val subscriptionNotification: SubscriptionNotification? = null,
    val oneTimeProductNotification: OneTimeProductNotification? = null,
    val voidedPurchaseNotification: VoidedPurchaseNotification? = null,
    val testNotification: TestNotification? = null
)
```

### Step 6: Dispatch by notification shape

Route by which sub object is present, then by type code.

```kotlin
fun route(n: DeveloperNotification) {
    when {
        n.subscriptionNotification != null ->
            handleSubscription(n.subscriptionNotification)
        n.oneTimeProductNotification != null ->
            handleOneTime(n.oneTimeProductNotification)
        n.voidedPurchaseNotification != null ->
            handleVoided(n.voidedPurchaseNotification)
        n.testNotification != null ->
            log("RTDN test received")
    }
}
```

### Step 7: Deduplicate before processing

```kotlin
suspend fun onPubSubMessage(
    messageId: String,
    n: DeveloperNotification
) {
    if (store.hasProcessed(messageId)) return
    route(n)
    store.markProcessed(messageId)
}
```

### Step 8: Always call the API

```kotlin
suspend fun handleSubscription(s: SubscriptionNotification) {
    metrics.increment("rtdn.sub.${s.notificationType}")
    val sub = playApi.getSubscriptionV2(
        packageName, s.purchaseToken
    )
    updateEntitlementFromApiState(s.purchaseToken, sub)
}
```

Apply the same pattern to one time products (`purchases.products.get`) and voided purchases (revoke the entitlement keyed on the purchase token).

### Notification type reference

Chapter 10 of the handbook documents the 14 subscription types, 2 one time product types, voided purchase, and test notification. The full catalog of 22 subscription notification types (including newer types such as pending plan changes and winback acceptances) is maintained in Appendix A of the handbook. See the [RTDN chapter on revenuecat.com](https://www.revenuecat.com/guides/google-play-billing/real-time-developer-notifications-rtdn) for in depth coverage of each type; see the [rtdn-reference](../rtdn-reference/) skill or the appendix linked from it for the complete list.

Key subscription types you must handle correctly:

| Type | Code | Action |
|------|------|--------|
| SUBSCRIPTION_RECOVERED | 1 | Restore access; payment recovered from hold |
| SUBSCRIPTION_RENEWED | 2 | Extend expiry to new `expiryTimeMillis` |
| SUBSCRIPTION_CANCELED | 3 | Keep access until `expiryTimeMillis`; do not revoke now |
| SUBSCRIPTION_PURCHASED | 4 | Server side safety net; verify the purchase |
| SUBSCRIPTION_ON_HOLD | 5 | Revoke access; keep the subscription record |
| SUBSCRIPTION_IN_GRACE_PERIOD | 6 | Keep access; surface a payment update prompt |
| SUBSCRIPTION_RESTARTED | 7 | User resubscribed before expiry; confirm auto renewing |
| SUBSCRIPTION_PRICE_CHANGE_CONFIRMED | 8 | Record new price for next renewal |
| SUBSCRIPTION_DEFERRED | 9 | Fetch new expiry time and extend access |
| SUBSCRIPTION_PAUSED | 10 | Revoke access until resume |
| SUBSCRIPTION_PAUSE_SCHEDULE_CHANGED | 11 | Sync pause schedule with API state |
| SUBSCRIPTION_REVOKED | 12 | Revoke access immediately |
| SUBSCRIPTION_EXPIRED | 13 | Terminal; revoke if not already |
| SUBSCRIPTION_PENDING_PURCHASE_CANCELED | 14 | Clean up pending record; no revocation needed |

One time products: `ONE_TIME_PRODUCT_PURCHASED (1)` and `ONE_TIME_PRODUCT_CANCELED (2)`. Voided purchases: always revoke and record for reconciliation; `productType` marks subscription (1) vs one time (2) and `refundType` marks full (1) vs quantity based (2).

## Phase 4: Verify

- Fire a test notification from Play Console and confirm the webhook logs a `testNotification` payload.
- Run an end to end sandbox purchase, cancel it, and verify you receive `SUBSCRIPTION_PURCHASED` then `SUBSCRIPTION_CANCELED` with matching purchase tokens.
- Replay the same Pub/Sub `messageId` twice and confirm your handler runs the business logic exactly once.
- Shuffle two notifications for the same token and confirm the final database state matches the API response rather than the order of delivery.
- Temporarily return `500` from the webhook and confirm Pub/Sub retries and eventually delivers after you return to `200`.
- Check the Pub/Sub subscription metrics for oldest unacked age; it should stay close to zero in steady state.
- Run a periodic reconciliation job that polls a sample of subscriptions against the API. If it finds drift, your RTDN pipeline has gaps to investigate.

## References

- [Full chapter](https://www.revenuecat.com/guides/google-play-billing/real-time-developer-notifications-rtdn)
