---
name: billing-response-codes
description: Use this skill as a reference lookup for every Play Billing Library BillingResponseCode and sub response code, with description, category, and handling guidance. Grounded in PBL 9.x.
license: Apache-2.0; see LICENSE
metadata:
  author: RevenueCat
  source: google-play-handbook appendix B
  keywords:
  - android
  - play-billing
  - billingresponsecode
  - reference
  - error-codes
---

# Billing Response Codes

## Phase 0: Intent

Use this skill when you need to look up the meaning, category, or handling strategy for a value returned by `BillingResult.getResponseCode()` or `BillingResult.getOnPurchasesUpdatedSubResponseCode()` in the Play Billing Library. This reference covers:

- All `BillingResponseCode` constants defined in PBL 9.x (the constant set is unchanged from PBL 8.x; v9 added no codes and removed none).
- All `OnPurchasesUpdatedSubResponseCode` constants added in PBL 8.0.
- Retry eligibility for each code.
- The recommended response strategy per code.
- A decision tree that maps any received code to an action.

Use this skill to answer questions like "what does response code 7 mean", "should I retry on `SERVICE_UNAVAILABLE`", or "how do I handle `ITEM_ALREADY_OWNED`".

Do not use this skill to author new integration code from scratch. Use the launch or purchase flow skills for that. This skill is a lookup table.

## Phase 1: Locate

The authoritative copy of the tables and decision tree lives in the [full appendix on revenuecat.com](https://www.revenuecat.com/guides/google-play-billing/appendix-billingresult-response-code-reference). When a question asks for:

- The literal integer value of a code, see "Response Codes".
- Sub response codes introduced in PBL 8.0, see "Sub Response Codes (PBL 8.0+)".
- The retry strategy for a code, see "Retry Implementation Summary".
- A full flow from received code to action, see "Error Handling Decision Tree".

The tables reproduced below in Phase 2 mirror the appendix verbatim so you can answer most lookups without opening the chapter.

## Phase 2: Reference Tables

### BillingResponseCode values

| Code | Value | Retriable | Description | Recommended Strategy |
|------|-------|-----------|-------------|---------------------|
| `OK` | 0 | N/A | Operation succeeded | Process the result normally. |
| `USER_CANCELED` | 1 | No | User dismissed the purchase dialog. Since PBL 8.3 also returned when the user left to pay in an external app (e-wallet) and did not return (debug message `BILLING_ACTIVITY_PAUSED`; `ERROR` before 8.3). | No action needed. Do not show an error message. |
| `SERVICE_UNAVAILABLE` | 2 | Yes | Google Play service is temporarily unavailable | Retry with exponential backoff (2s base, 2x factor, max 3 attempts). |
| `BILLING_UNAVAILABLE` | 3 | No (auto) | Billing is unavailable on this device or for this user | Do not auto retry. Check Play Store version and user account. Let the user try again manually. **PBL 9** (with androidx.core 1.9+) also routes a system blocked Play Store here with a "Play Store is blocked" `debugMessage`, where PBL 8 returned `ERROR`. |
| `ITEM_UNAVAILABLE` | 4 | No | The requested product is not available for purchase | Refresh product details with `queryProductDetailsAsync()`. The product may have been deactivated. |
| `DEVELOPER_ERROR` | 5 | No | Invalid arguments passed to the API | Fix your code. Check product IDs, offer tokens, and parameter construction. This is a programming error. |
| `ERROR` | 6 | Yes | An internal Google Play error occurred | Retry with exponential backoff. If persistent, report to Google. |
| `ITEM_ALREADY_OWNED` | 7 | No | The user already owns this item (a subscription, a non consumable, or a consumable that has not been consumed yet) | Call `queryPurchasesAsync()` to refresh your local purchase cache. The user may have purchased on another device. |
| `ITEM_NOT_OWNED` | 8 | No | Attempted to consume or acknowledge an item the user does not own | Call `queryPurchasesAsync()` to refresh your local purchase cache. The purchase may have been refunded. |
| `NETWORK_ERROR` | 12 | Yes | A network error occurred during the operation | Retry with a short delay (1-2 seconds). Check device connectivity. |
| `SERVICE_DISCONNECTED` | -1 | Yes | The `BillingClient` is not connected to the Play Store billing service | With `enableAutoServiceReconnection()` (opt in, PBL 8+) the library reconnects before the next call; if you still get this code, retry the call (simple retry in session, exponential backoff in the background). Without it, call `startConnection()` and retry. |
| `FEATURE_NOT_SUPPORTED` | -2 | No | The requested feature is not supported on this device or Play Store version | Check `isFeatureSupported()` before calling feature specific APIs. Provide fallback behavior. |
| `SERVICE_TIMEOUT` | -3 | Yes (Deprecated) | The request timed out | Deprecated in recent PBL versions. Treat as `SERVICE_UNAVAILABLE` and retry with backoff. |

### Sub Response Codes (PBL 8.0+)

Sub response codes provide more granular information about why a purchase failed. They are only available in the `PurchasesUpdatedListener.onPurchasesUpdated()` callback, retrieved via `BillingResult.getOnPurchasesUpdatedSubResponseCode()`.

| Sub Response Code | Description | When It Appears | Recommended Action |
|-------------------|-------------|-----------------|-------------------|
| `NO_APPLICABLE_SUB_RESPONSE_CODE` | No specific sub response applies | Default value for most responses | Handle based on the main response code only. |
| `PAYMENT_DECLINED_DUE_TO_INSUFFICIENT_FUNDS` | User's available funds are less than the purchase price | When the main response indicates a payment failure | Show a message suggesting the user check their payment method balance. |
| `USER_INELIGIBLE` | User does not meet eligibility requirements for an offer | When the user attempts to use an offer they are not eligible for | Show standard pricing without the offer. Check your offer eligibility logic. |

### Accessing sub response codes

```kotlin
val listener = PurchasesUpdatedListener { billingResult, purchases ->
    if (billingResult.responseCode != BillingResponseCode.OK) {
        val subCode = billingResult.onPurchasesUpdatedSubResponseCode
        when (subCode) {
            OnPurchasesUpdatedSubResponseCode.PAYMENT_DECLINED_DUE_TO_INSUFFICIENT_FUNDS ->
                showInsufficientFundsMessage()
            OnPurchasesUpdatedSubResponseCode.USER_INELIGIBLE ->
                showStandardPricing()
            else -> handleGeneralError(billingResult)
        }
    }
}
```

### Retry strategy summary

| Strategy | Base Delay | Factor | Max Attempts | Use For |
|----------|------------|--------|--------------|---------|
| Simple retry | 1-2 seconds | 1x (fixed) | 3 | `NETWORK_ERROR` |
| Exponential backoff | 2 seconds | 2x | 3 | `SERVICE_UNAVAILABLE`, `ERROR`, `SERVICE_TIMEOUT` |
| Reconnect, then retry | Library (auto reconnection) or `startConnection()` | Simple in session, backoff in background | 3 | `SERVICE_DISCONNECTED` |
| User initiated | N/A | N/A | N/A | `BILLING_UNAVAILABLE` |
| No retry | N/A | N/A | N/A | `USER_CANCELED`, `DEVELOPER_ERROR`, `FEATURE_NOT_SUPPORTED` |

## Phase 3: Handling Guidance

When you receive a `BillingResult`, walk it through this decision tree:

1. **Is `responseCode` equal to `OK`?**
   - Yes: process the result. Done.
   - No: continue.

2. **Is `responseCode` equal to `USER_CANCELED`?**
   - Yes: do nothing. The user chose to cancel. Done.
   - No: continue.

3. **Is the error retriable?** (`SERVICE_UNAVAILABLE`, `ERROR`, `NETWORK_ERROR`, `SERVICE_DISCONNECTED`, `SERVICE_TIMEOUT`)
   - Yes: retry with the matching strategy from the retry summary table. Simple retry for `NETWORK_ERROR`, exponential backoff for service errors. If all retries fail, show an error message.
   - No: continue.

4. **Is it a cache sync issue?** (`ITEM_ALREADY_OWNED`, `ITEM_NOT_OWNED`)
   - Yes: call `queryPurchasesAsync()` to refresh your purchase cache. Update UI accordingly.
   - No: continue.

5. **Is it a product issue?** (`ITEM_UNAVAILABLE`)
   - Yes: refresh product details. The product may no longer be available.
   - No: continue.

6. **Is it a device or environment issue?** (`BILLING_UNAVAILABLE`, `FEATURE_NOT_SUPPORTED`)
   - Yes: show a user facing message. Do not retry automatically. Let the user initiate a retry.
   - No: continue.

7. **Is it a developer error?** (`DEVELOPER_ERROR`)
   - Yes: log the error with full details. Fix the API usage in your code. This should not happen in production.

### Category quick reference

Group each code into one of six buckets so you can route it to the right handler:

- Success: `OK`.
- User intent: `USER_CANCELED`.
- Transient service or network: `SERVICE_UNAVAILABLE`, `ERROR`, `NETWORK_ERROR`, `SERVICE_DISCONNECTED`, `SERVICE_TIMEOUT`.
- Cache sync: `ITEM_ALREADY_OWNED`, `ITEM_NOT_OWNED`.
- Catalog or product: `ITEM_UNAVAILABLE`.
- Environment or configuration: `BILLING_UNAVAILABLE`, `FEATURE_NOT_SUPPORTED`.
- Programming error: `DEVELOPER_ERROR`.

### Checking a code with `when`

```kotlin
fun classify(code: Int): Category = when (code) {
    BillingResponseCode.OK -> Category.SUCCESS
    BillingResponseCode.USER_CANCELED -> Category.USER_INTENT
    BillingResponseCode.SERVICE_UNAVAILABLE,
    BillingResponseCode.ERROR,
    BillingResponseCode.NETWORK_ERROR,
    BillingResponseCode.SERVICE_DISCONNECTED,
    BillingResponseCode.SERVICE_TIMEOUT -> Category.TRANSIENT
    BillingResponseCode.ITEM_ALREADY_OWNED,
    BillingResponseCode.ITEM_NOT_OWNED -> Category.CACHE_SYNC
    BillingResponseCode.ITEM_UNAVAILABLE -> Category.CATALOG
    BillingResponseCode.BILLING_UNAVAILABLE,
    BillingResponseCode.FEATURE_NOT_SUPPORTED -> Category.ENVIRONMENT
    BillingResponseCode.DEVELOPER_ERROR -> Category.PROGRAMMING
    else -> Category.UNKNOWN
}
```

## References

- [Full chapter](https://www.revenuecat.com/guides/google-play-billing/appendix-billingresult-response-code-reference)

- Google Play Billing Library reference for `BillingResponseCode`: https://developer.android.com/reference/com/android/billingclient/api/BillingClient.BillingResponseCode
- Google Play Billing Library reference for `OnPurchasesUpdatedSubResponseCode`: https://developer.android.com/reference/com/android/billingclient/api/BillingClient.OnPurchasesUpdatedSubResponseCode
