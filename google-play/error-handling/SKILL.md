---
name: error-handling
description: Use this skill when designing error handling and retry strategy for the Play Billing Library. Classifies every BillingResponseCode into recoverable, non recoverable, and user driven categories and builds a retry plan with exponential backoff and circuit breaker patterns.
license: Apache-2.0; see LICENSE
metadata:
  author: RevenueCat
  source: google-play-handbook chapter 8
  keywords:
  - android
  - play-billing
  - error-handling
  - billingresponsecode
  - retry
  - exponential-backoff
  - circuit-breaker
---

# Error Handling and Retry Strategies

Every Play Billing Library call can fail. Network connections drop, the Play Store app updates or restarts, users cancel purchases, and payment methods get declined. This skill gives you a phased path from reading a `BillingResult` to shipping a retry layer that recovers gracefully without hammering Google's servers.

## Phase 1: Read BillingResult correctly

Every PBL operation returns a `BillingResult` with two fields. Treat them asymmetrically.

- `responseCode` is the integer constant you branch on. Always use the constants from `BillingClient.BillingResponseCode`, never the raw integer.
- `debugMessage` is a log only string. Google can change the text at any time, so never parse it and never show it to users.

```kotlin
// PBL 9.x
val billingResult = billingClient.acknowledgePurchase(params)
when (billingResult.responseCode) {
    BillingClient.BillingResponseCode.OK -> { /* proceed */ }
    BillingClient.BillingResponseCode.NETWORK_ERROR -> { /* retry */ }
    else -> Log.e("Billing", billingResult.debugMessage)
}
```

PBL 8.0 added sub response codes, read in `PurchasesUpdatedListener` with `BillingResult.getOnPurchasesUpdatedSubResponseCode()` (Kotlin: `billingResult.onPurchasesUpdatedSubResponseCode`). Two are worth branching on:

- `PAYMENT_DECLINED_DUE_TO_INSUFFICIENT_FUNDS` arrives under a top level `ERROR` and lets you suggest a different payment method instead of a generic failure screen.
- `USER_INELIGIBLE` tells you the user does not qualify for the offer, so you can show alternatives they do qualify for.

Not every failure carries a sub response code. Check presence before acting.

## Phase 2: Classify every response code

Before you write retry code, place every code in one of four buckets. Retriable codes drive loops. User driven codes drive UI prompts. Cache sync codes drive a refresh then replay. Terminal codes surface an error message and stop.

| Response Code | Value | Category | Action |
|---|---|---|---|
| OK | 0 | Success | Proceed |
| USER_CANCELED | 1 | Ignore | Return silently to previous screen |
| SERVICE_UNAVAILABLE | 2 | Retriable | Exponential backoff |
| BILLING_UNAVAILABLE | 3 | User driven | Show a generic unavailable message with a Try again button; never auto retry |
| ITEM_UNAVAILABLE | 4 | Cache sync | Refresh product details |
| DEVELOPER_ERROR | 5 | Terminal | Fix code, log debugMessage |
| ERROR | 6 | Retriable | Exponential backoff |
| ITEM_ALREADY_OWNED | 7 | Cache sync | Refresh purchases, grant access |
| ITEM_NOT_OWNED | 8 | Cache sync | Refresh purchases |
| NETWORK_ERROR | 12 | Retriable | Simple retry with short delay |
| SERVICE_DISCONNECTED | -1 | Reconnect | With `enableAutoServiceReconnection()`: retry the call (simple in session, backoff in background). Without it: call startConnection, then retry |
| SERVICE_TIMEOUT | -3 | Retriable (deprecated, not returned since PBL 6) | Treat as SERVICE_UNAVAILABLE |
| FEATURE_NOT_SUPPORTED | -2 | Terminal | Hide feature in UI |

A few classification notes:

- `BILLING_UNAVAILABLE` means billing is unavailable for this user or device (outdated Play Store, unsupported country, purchases disabled by an admin, payment method cannot be charged). Never auto retry; offer a "try again" button. **As of PBL 9** (with androidx.core 1.9+), a Play Store blocked by the system (for example an OEM customized kids mode) reports `BILLING_UNAVAILABLE` instead of `ERROR`, with a "Play Store is blocked" `debugMessage`. Handle it like any other `BILLING_UNAVAILABLE`; log the debug message but do not branch on its text.
- `ITEM_ALREADY_OWNED` often means a purchase succeeded but your app crashed before processing it. Refresh purchases and grant access instead of showing an error.
- `DEVELOPER_ERROR` should never reach production. If you see it in logs, fix the call site (invalid product ID, wrong product type, calling before connection is ready).
- `FEATURE_NOT_SUPPORTED` is answered at startup by calling `isFeatureSupported` once and hiding unsupported features.
- `SERVICE_DISCONNECTED` (`BillingAction.Reconnect`): enable `enableAutoServiceReconnection()` (PBL 8+) when building the client; with it, `Reconnect` means retry the call, not call `startConnection()` yourself.

Model the classification as a sealed action type so decisions are unit testable without a `BillingClient`:

```kotlin
// PBL 9.x
sealed class BillingAction {
    data object Success : BillingAction()
    data object RetrySimple : BillingAction()
    data object RetryBackoff : BillingAction()
    data object Reconnect : BillingAction()
    data object RefreshPurchases : BillingAction()
    data object RefreshProducts : BillingAction()
    data object UserRetry : BillingAction()
    data object Ignore : BillingAction()
    data class Fail(val msg: String) : BillingAction()
}
```

```kotlin
// PBL 9.x
fun decideBillingAction(code: Int) = when (code) {
    BillingResponseCode.OK -> BillingAction.Success
    BillingResponseCode.NETWORK_ERROR -> BillingAction.RetrySimple
    BillingResponseCode.SERVICE_UNAVAILABLE,
    BillingResponseCode.ERROR,
    BillingResponseCode.SERVICE_TIMEOUT -> BillingAction.RetryBackoff
    BillingResponseCode.SERVICE_DISCONNECTED -> BillingAction.Reconnect
    BillingResponseCode.ITEM_ALREADY_OWNED,
    BillingResponseCode.ITEM_NOT_OWNED -> BillingAction.RefreshPurchases
    BillingResponseCode.ITEM_UNAVAILABLE -> BillingAction.RefreshProducts
    BillingResponseCode.BILLING_UNAVAILABLE -> BillingAction.UserRetry
    BillingResponseCode.USER_CANCELED -> BillingAction.Ignore
    else -> BillingAction.Fail("Non retriable: $code")
}
```

## Phase 3: Build the retry layer

Retriable codes split into two policies. Network level noise uses a short fixed delay. Server side overload uses exponential backoff with jitter. Add a circuit breaker on top so a failing downstream stops burning user battery and retry budget.

### Simple retry for NETWORK_ERROR

Start at one to two seconds, cap at three attempts, and always check the response code instead of catching exceptions (PBL returns results, it does not throw).

```kotlin
// PBL 9.x
suspend fun retryOnBillingError(
    maxAttempts: Int = 3,
    delayMs: Long = 1_000L,
    retriable: Set<Int>,
    block: suspend () -> BillingResult
): BillingResult {
    var last: BillingResult? = null
    repeat(maxAttempts) { attempt ->
        val r = block()
        if (r.responseCode !in retriable) return r
        last = r
        if (attempt < maxAttempts - 1) delay(delayMs)
    }
    return last!!
}
```

### Exponential backoff with jitter for SERVICE_UNAVAILABLE, ERROR, and SERVICE_TIMEOUT

Double the delay each attempt so overloaded services can recover. Add random jitter so thousands of devices do not retry in lockstep after a regional outage.

```kotlin
// PBL 9.x
suspend fun retryWithBackoff(
    maxAttempts: Int = 3,
    baseDelayMs: Long = 2_000L,
    factor: Double = 2.0,
    block: suspend () -> BillingResult
): BillingResult {
    var last: BillingResult? = null
    repeat(maxAttempts) { attempt ->
        val r = block()
        if (r.responseCode !in RETRIABLE_BACKOFF) return r
        last = r
        if (attempt < maxAttempts - 1) {
            val base = baseDelayMs * factor.pow(attempt.toDouble())
            val jitter = Random.nextLong(0, baseDelayMs / 2)
            delay(base.toLong() + jitter)
        }
    }
    return last!!
}
```

With base two seconds and factor two, the waits are 2s then 4s (plus up to 1s jitter each). Three attempts finish inside roughly six seconds of waiting, which is acceptable for an in flight purchase and gives Google room to breathe.

### Circuit breaker to stop cascading failures

When a downstream keeps failing, the breaker opens and short circuits further calls for a cooldown window. This protects battery, prevents retry storms, and surfaces a user actionable error quickly.

```kotlin
// PBL 9.x
class BillingCircuitBreaker(
    private val threshold: Int = 5,
    private val cooldownMs: Long = 30_000L
) {
    private var failures = 0
    private var openedAt = 0L
    fun isOpen(): Boolean =
        failures >= threshold &&
            System.currentTimeMillis() - openedAt < cooldownMs
    fun recordSuccess() { failures = 0 }
    fun recordFailure() {
        failures++
        if (failures >= threshold) openedAt = System.currentTimeMillis()
    }
}
```

Wire the breaker around the retry policies so an open circuit skips the call entirely:

```kotlin
// PBL 9.x
suspend fun guarded(
    breaker: BillingCircuitBreaker,
    block: suspend () -> BillingResult
): BillingResult {
    if (breaker.isOpen()) return BillingResult.newBuilder()
        .setResponseCode(BillingResponseCode.SERVICE_UNAVAILABLE)
        .setDebugMessage("circuit open").build()
    val r = block()
    if (r.responseCode == BillingResponseCode.OK) breaker.recordSuccess()
    else breaker.recordFailure()
    return r
}
```

## Phase 4: Handle onPurchasesUpdated and user messaging

`onPurchasesUpdated` is the one callback where wrong error handling directly costs users the content they paid for. Three rules:

1. Null check `purchases` even when `responseCode` is `OK`.
2. `USER_CANCELED` emits zero UI, zero analytics failures, zero prompts. Return to the previous screen.
3. `ITEM_ALREADY_OWNED` triggers a purchase refresh and grants access silently. The user already paid.

User messaging maps directly to categories:

- Retriable in progress: show a subtle loading indicator, never flash errors between attempts.
- Retries exhausted: "Something went wrong. Please try again." with a retry button.
- `BILLING_UNAVAILABLE`: "Purchases aren't available on this device or account right now. Please try again later."
- Payment declined sub code: "Your payment method was declined. Please update your payment method in Google Play and try again."
- Never show raw response codes or `debugMessage` text to users.

Remember to acknowledge successful purchases within three days or Google refunds them automatically.

## References

- [Full chapter](https://www.revenuecat.com/guides/google-play-billing/error-handling-and-retry-strategies)
