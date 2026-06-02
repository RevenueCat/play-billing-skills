---
name: cancellations-pauses-winback
description: Use this skill when implementing cancellations, developer initiated revocations, subscription pauses, and winback offers on Google Play. Covers user initiated cancellation, system cancellation, developer revoke/refund, pause resume flow, and winback API tools.
license: Apache-2.0; see LICENSE
metadata:
  author: RevenueCat
  source: google-play-handbook chapter 13
  keywords:
  - android
  - play-billing
  - cancellation
  - pause
  - winback
  - churn
---

# Cancellations, Pauses, and Winback

A subscription can end in several ways, and each one has a different effect on user access, entitlement records, and recovery options. Use this skill when you are wiring up any end of life or pause flow for a Google Play subscription: user cancellation, developer cancellation, system cancellation after payment failure, pause, resume, restore, resubscribe, deferral, or revocation.

## Phase 1: Identify the Scenario

Before writing any code, identify which of the following you are handling. The later phases branch on this choice.

- The user is canceling through Play (silent to your app, signaled by RTDN).
- You are canceling from your backend on the user's behalf or for your own reasons.
- Google canceled after exhausting grace period and account hold.
- The user is pausing, resuming, or a pause is scheduled.
- The user is restoring a cancellation before expiry, or resubscribing after expiry.
- You are deferring billing as goodwill or compensation.
- You are revoking immediately due to fraud or a terms violation.

## Phase 2: Plan by Cancellation Type

Each cancellation type behaves differently with respect to access, refunds, RTDN signals, and recovery. Plan the entitlement logic using the matrix below before you touch the API.

### Cancellation type matrix

| Type | API or Trigger | Access After | Refund | Primary RTDN | canceledStateContext.cancellationReason |
|---|---|---|---|---|---|
| User initiated | Play Subscriptions Center | Until `expiryTime` | None (prorated not issued) | `SUBSCRIPTION_CANCELED` | `USER_CANCELED` |
| Developer, user requested | `purchases.subscriptionsv2.cancel` with `USER_REQUESTED_STOP_RENEWAL` | Until `expiryTime` | None | `SUBSCRIPTION_CANCELED` | `DEVELOPER_CANCELED` |
| Developer, your reason | `purchases.subscriptionsv2.cancel` with `DEVELOPER_REQUESTED_STOP_PAYMENTS` | Until `expiryTime` | None | `SUBSCRIPTION_CANCELED` | `DEVELOPER_CANCELED` |
| System, payment failure | Automatic after grace + account hold | None from the moment account hold expires | None | `SUBSCRIPTION_CANCELED` | `SYSTEM_CANCELED` |
| Replacement (plan change) | Plan change flow | Handled by new token | N/A | `SUBSCRIPTION_CANCELED` on old token | `REPLACED` |
| Revoke | `purchases.subscriptionsv2.revoke` | Immediately terminated | Prorated refund issued by Google | `SUBSCRIPTION_REVOKED` | n/a (terminated) |

### Pause versus cancel

| Signal | What it means | Access |
|---|---|---|
| `SUBSCRIPTION_PAUSE_SCHEDULE_CHANGED` | Pause scheduled, starts at end of current billing period | Still active, full access |
| `SUBSCRIPTION_PAUSED` | Pause has begun | Revoke access |
| `SUBSCRIPTION_RECOVERED` | Pause ended, payment collected | Restore access |
| `SUBSCRIPTION_RESTARTED` | User restored a cancellation before `expiryTime` | Access uninterrupted, same token |

### Installment subscription caveat

During the commitment period of an installment plan, a user cancellation is either blocked outright or scheduled for after the commitment. A scheduled cancellation arrives as `SUBSCRIPTION_CANCELLATION_SCHEDULED`, not `SUBSCRIPTION_CANCELED`. Treat scheduled cancellation as "user intends to leave, still paying". Do not revoke access. The final `SUBSCRIPTION_CANCELED` arrives later when the commitment completes.

### Entitlement rule that applies to every type

A canceled subscription with a future `expiryTime` is still an active subscription from the user's perspective. The only exceptions are revocation (immediate) and `SUBSCRIPTION_PAUSED` (immediate).

## Phase 3: Execute

Use the snippets below as starting points. Each one matches a specific API call or RTDN handler from Phase 2.

### Entitlement check that survives cancellation

```kotlin
fun hasActiveSubscription(
    subscription: SubscriptionPurchaseV2
): Boolean {
    val now = System.currentTimeMillis()
    val expiry = subscription.lineItems
        .firstOrNull()
        ?.expiryTime
        ?.toEpochMilliseconds() ?: return false
    return now < expiry
}
```

### Inspect canceledStateContext to segment churn

```kotlin
fun logCancellationReason(
    subscription: SubscriptionPurchaseV2
) {
    val context = subscription.canceledStateContext ?: return
    when (context.cancellationReason) {
        "USER_CANCELED" -> analytics.trackChurn(
            reason = "user",
            surveyResponse = context.userInitiatedCancellation
                ?.cancelSurveyResult?.reason
        )
        "SYSTEM_CANCELED" -> analytics.trackChurn(reason = "payment_failure")
        "DEVELOPER_CANCELED" -> analytics.trackChurn(reason = "developer")
    }
}
```

This mapping is what drives later winback decisions. A "too expensive" survey answer is a discount candidate. A payment failure is a payment update prompt. A fraud cancellation is not a winback candidate.

### Developer initiated cancellation

Call `purchases.subscriptionsv2.cancel` with the package name, purchase token, and one of the two reasons:

- `USER_REQUESTED_STOP_RENEWAL` when the user asked you to cancel.
- `DEVELOPER_REQUESTED_STOP_PAYMENTS` when you are canceling for your own reasons.

Both leave access intact until `expiryTime`. Pick the right reason so `canceledStateContext` records accurate analytics.

### Pause RTDN handler

```kotlin
fun handlePauseNotification(
    notificationType: Int,
    purchaseToken: String
) {
    when (notificationType) {
        11 -> markPauseScheduled(purchaseToken) // PAUSE_SCHEDULE_CHANGED
        10 -> revokeAccess(purchaseToken)       // PAUSED
        1  -> grantAccess(purchaseToken)        // RECOVERED
    }
}
```

### Surface paused subscriptions on the client (PBL 8.1+)

```kotlin
val params = QueryPurchasesParams.newBuilder()
    .setProductType(ProductType.SUBS)
    .setIncludeSuspendedSubscriptions(true)
    .build()

val result = billingClient.queryPurchasesAsync(params)
```

A suspended purchase returns `purchaseState == PURCHASED`. Do not grant access. Use it to drive a "paused, resume now" UI.

### Restore before expiry

```kotlin
fun handleSubscriptionRestarted(purchaseToken: String) {
    val record = database.findByPurchaseToken(purchaseToken) ?: return
    record.canceledAt = null
    record.status = "ACTIVE"
    database.update(record)
}
```

The purchase token does not change on restore.

### Link a resubscribe to the original account

```kotlin
fun handleResubscribe(new: SubscriptionPurchaseV2) {
    val expired = new.expiredExternalAccountIdentifiers
    val user = expired?.externalAccountId?.let {
        database.findByExternalAccountId(it)
    }
    if (user != null) {
        database.addSubscription(user.id, new.purchaseToken, "ACTIVE")
    } else {
        handleNewSubscription(new)
    }
}
```

Prerequisite: set `externalAccountId` on the original purchase with `BillingFlowParams.Builder.setExternalAccountId(userId)`. Without it, `expiredExternalAccountIdentifiers` is empty on resubscribe.

### Defer billing

```kotlin
fun deferSubscription(
    packageName: String,
    purchaseToken: String
) {
    val current = getSubscriptionExpiry(packageName, purchaseToken)
    val newExpiry = current.plus(14, ChronoUnit.DAYS)
    playApi.purchases().subscriptionsv2()
        .defer(packageName, purchaseToken, DeferRequest(newExpiry))
        .execute()
}
```

Constraints: minimum 1 day beyond current expiry, maximum 1 year, new expiry must be in the future. Deferral keeps the same token and can be applied multiple times. It does not work on canceled subscriptions.

### Revoke immediately

```kotlin
fun revokeSubscription(
    packageName: String,
    purchaseToken: String,
    reason: String
) {
    playApi.purchases().subscriptionsv2()
        .revoke(packageName, purchaseToken, RevokeRequest(reason))
        .execute()
    database.findByPurchaseToken(purchaseToken)?.let {
        it.status = "REVOKED"
        database.update(it)
    }
}
```

Revocation is appropriate for confirmed fraud, serious terms of service violations, or proactive chargeback response. It is not a substitute for a standard cancel plus refund. Google issues a prorated refund automatically and sends `SUBSCRIPTION_REVOKED` so your backend can reconcile even if the local write failed.

## Winback Eligibility Checks

Use the `canceledStateContext.cancellationReason` from Phase 3 to decide who is eligible for a winback offer:

- `USER_CANCELED` with a price related survey answer: discount offer.
- `SYSTEM_CANCELED`: payment method update prompt, not a discount.
- `DEVELOPER_CANCELED` with `DEVELOPER_REQUESTED_STOP_PAYMENTS` due to fraud or TOS: exclude from winback.
- `REPLACED`: not a churn event, exclude.

A paused subscriber is not a winback candidate either. They have already signaled intent to return, so the right surface is a resume prompt, not a discount.

## References

- [Full chapter](https://www.revenuecat.com/guides/google-play-billing/cancellations-pauses-and-winback)
