---
name: subscription-states
description: Use this skill when mapping a Google Play subscription to the eight states (PENDING, ACTIVE, IN_GRACE_PERIOD, ON_HOLD, PAUSED, CANCELED, EXPIRED, PENDING_PURCHASE_CANCELED) and deciding what access your app should grant in each state.
license: Apache-2.0; see LICENSE
metadata:
  author: RevenueCat
  source: google-play-handbook chapter 11
  keywords:
  - android
  - play-billing
  - subscriptions
  - subscription-state
  - state-machine
  - entitlement
---

# Subscription States

A Google Play subscription moves through eight states between the first purchase and final termination. Each state has a concrete access decision: grant, retain until expiry, or revoke. Get the mapping wrong and you either give away paid content or revoke access a user already paid for.

This skill walks you through confirming your app reads the correct state source, deciding the access rule for each state, and writing the mapping code.

## Phase 1: Discovery

Before changing anything, confirm where your entitlement decision reads subscription state from. The authoritative source is the `subscriptionState` field on the `SubscriptionPurchaseV2` resource returned by `purchases.subscriptionsv2.get` on the Google Play Developer API. The client `Purchase` object from `queryPurchasesAsync()` does not carry this field.

Answer these questions:

1. Does your backend call `purchases.subscriptionsv2.get` (not the legacy `purchases.subscriptions.get`)?
2. Does your entitlement function read `subscriptionState` from that response rather than inferring state from the RTDN notification type?
3. Does the function check `expiryTime` when the state is `SUBSCRIPTION_STATE_CANCELED`?
4. Does your client code treat a `Purchase` returned by `queryPurchasesAsync()` as "has a purchase," not "has access"?

If any answer is no, fix the source of truth first. Inferring state from the notification type is the single most common cause of wrong entitlement decisions, because two different transitions can produce the same RTDN type. For example, `SUBSCRIPTION_RECOVERED` fires both when a user fixes payment during account hold and when a paused subscription resumes, while a payment fixed during grace period arrives as `SUBSCRIPTION_RENEWED`.

Confirm the app is on subscriptionsv2 before moving on.

## Phase 2: Plan the Decision Per State

Decide the access rule for each of the eight states. Use this table as the contract your code must match:

| State | Access Decision | Reason |
|---|---|---|
| PENDING | Do not grant | Payment has not settled yet. |
| PENDING_PURCHASE_CANCELED | Do not grant on this token | Pending payment canceled or expired; if `linkedPurchaseToken` is set, the previous subscription keeps its own state. |
| ACTIVE | Grant | Paid and within the current billing period. |
| IN_GRACE_PERIOD | Grant | Payment failed, Google is retrying, user keeps access during the configured window. |
| CANCELED | Retain until `expiryTime` | User canceled but already paid for the current period. |
| ON_HOLD | Revoke | Grace period expired without recovery. |
| PAUSED | Revoke | Voluntary pause, no billing during the window. |
| EXPIRED | Revoke | Subscription has ended. |

Three rules flow from this table:

- Treat `CANCELED` as a delayed revocation, not an immediate one. Schedule the revocation for `expiryTime`.
- Treat `ON_HOLD` as an immediate revocation. A default `queryPurchasesAsync()` omits subscriptions in account hold; if you query with `includeSuspendedSubscriptions(true)` (PBL 8.1+), they come back with `isSuspended == true` and must not grant access.
- Treat `PENDING` as "no access yet." Wait for the transition to `ACTIVE` before entitling the user.

Plan the UI message for each revoking or warning state:

- `IN_GRACE_PERIOD`: show a "fix your payment" prompt with the Play Store deep link.
- `ON_HOLD`: show the same prompt, since recovery is still possible until the hold expires.
- `PAUSED`: show the resume date, not a payment failure message.
- `CANCELED`: show a resubscribe prompt that references `expiryTime`.
- `EXPIRED`: show a fresh purchase offer.

## Phase 3: Execute

### Map the state string to an access decision

Encode the decision table directly. Keep the function pure so it is easy to test.

```kotlin
fun shouldGrantAccess(
    state: String,
    expiryTimeMillis: Long
): Boolean = when (state) {
    "SUBSCRIPTION_STATE_ACTIVE",
    "SUBSCRIPTION_STATE_IN_GRACE_PERIOD" -> true
    "SUBSCRIPTION_STATE_CANCELED" ->
        System.currentTimeMillis() < expiryTimeMillis
    else -> false
}
```

Everything not listed (`ON_HOLD`, `PAUSED`, `EXPIRED`, `PENDING`, and anything unknown) returns `false`. This is the safe default.

### Gate the client path with the backend state

The client must not decide entitlement alone. The client cannot see grace period (it looks like a normal active purchase) and omits account hold unless `includeSuspendedSubscriptions(true)` is set, in which case check `isSuspended`.

```kotlin
suspend fun checkEntitlement(
    client: BillingClient,
    api: YourBackendApi
): Boolean {
    val params = QueryPurchasesParams.newBuilder()
        .setProductType(ProductType.SUBS).build()
    val result = client.queryPurchasesAsync(params)
    val purchase = result.purchasesList.firstOrNull()
        ?: return false
    if (purchase.purchaseState == PurchaseState.PENDING) {
        return false
    }
    return api.verifyEntitlement(purchase.purchaseToken)
}
```

The client check filters out "no purchase" and pending payments. The backend call resolves the real subscription state.

### Route the backend handler by state, not by notification type

When an RTDN arrives, fetch the subscription and branch on `subscriptionState`.

```kotlin
fun handle(notification: SubscriptionNotification) {
    val token = notification.purchaseToken
    val sub = playApi.getSubscriptionV2(pkg, token)
    when (sub.subscriptionState) {
        "SUBSCRIPTION_STATE_ACTIVE" -> grant(token)
        "SUBSCRIPTION_STATE_IN_GRACE_PERIOD" -> grantWithWarning(token)
        "SUBSCRIPTION_STATE_CANCELED" -> scheduleRevoke(token, sub)
        "SUBSCRIPTION_STATE_ON_HOLD",
        "SUBSCRIPTION_STATE_PAUSED",
        "SUBSCRIPTION_STATE_EXPIRED" -> revoke(token)
        "SUBSCRIPTION_STATE_PENDING" -> hold(token)
        "SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED" -> cleanUpPending(token, sub.linkedPurchaseToken)
    }
}
```

Schedule the `CANCELED` revocation at `expiryTime` so the user keeps the time they paid for.

```kotlin
fun scheduleRevoke(token: String, sub: SubscriptionPurchaseV2) {
    val expiry = Instant.parse(
        sub.lineItems.first().expiryTime
    ).toEpochMilli()
    if (System.currentTimeMillis() >= expiry) {
        revoke(token)
    } else {
        db.setExpiry(token, expiry)
        scheduler.scheduleAt(expiry) { revoke(token) }
    }
}
```

### Verify

Before shipping, confirm these behaviors with fixtures or a staging account:

- A `CANCELED` subscription with `expiryTime` in the future still grants access.
- An `ON_HOLD` subscription revokes access; `queryPurchasesAsync()` omits it by default or returns it with `isSuspended == true`.
- A `PENDING` subscription does not grant access until it transitions to `ACTIVE`.
- An unknown or new state string returns `false` rather than defaulting to `true`.

## References

- [Full chapter](https://www.revenuecat.com/guides/google-play-billing/the-subscription-state-machine)
