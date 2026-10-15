---
name: purchase-flow
description: Use this skill when implementing the Play Billing purchase flow end to end. Covers building BillingFlowParams, launching launchBillingFlow(), receiving results in PurchasesUpdatedListener, handling every BillingResult outcome, and posting to your backend.
license: Apache-2.0; see LICENSE
metadata:
  author: RevenueCat
  source: google-play-handbook chapter 6
  keywords:
  - android
  - play-billing
  - purchase-flow
  - billingflowparams
  - purchases-updated-listener
  - obfuscated-account-id
---

# Purchase Flow

Implements the full client side purchase sequence: build `BillingFlowParams`, launch `launchBillingFlow()`, receive callbacks in `PurchasesUpdatedListener`, handle every response code, then verify, acknowledge, and grant access.

## Phase 0: Intent

Use this skill when you need to:

- Launch a purchase from a "Buy" tap for a one time product or a subscription.
- Wire a `PurchasesUpdatedListener` and handle every `BillingResponseCode`.
- Decide where to verify, where to acknowledge, and how to grant entitlements idempotently.
- Support pending transactions (cash at convenience store, carrier billing, slow card auth).
- Sell subscriptions with add ons (several subscription items in one transaction).

Out of scope: connecting `BillingClient`, querying `ProductDetails`, subscription upgrades or downgrades, and retry or error taxonomy beyond the launch results listed below.

## Phase 1: Discovery

Confirm the preconditions before you build params.

| Check | How | Why |
|---|---|---|
| `BillingClient` connected | `billingClient.isReady == true` | Calls fail without a live connection. |
| `ProductDetails` cached | Held from a prior `queryProductDetailsAsync` | Required input to `ProductDetailsParams`. |
| Pending purchases enabled | `BillingClient.Builder.enablePendingPurchases(...)` was called | Users with delayed payment cannot buy otherwise. |
| Existing ownership known | Ran `queryPurchasesAsync()` recently | Prevents `ITEM_ALREADY_OWNED` surprises. |
| Offer token resolved | Subs: from `subscriptionOfferDetails`. One time: from `oneTimePurchaseOfferDetailsList` when the product has several purchase options or offers | A missing subs token returns `DEVELOPER_ERROR`; a missing one time token silently buys the default purchase option. |

Record the product type (`INAPP` vs `SUBS`), the selected `basePlanId`, and the chosen `offerToken` before moving on.

## Phase 2: Plan

Decide the following before you call `newBuilder()`.

### Account identifiers

- **obfuscatedAccountId**: attach a one way hash of your internal user id. Never pass raw email or plain text. Helps Google Play detect fraud across devices.
- **obfuscatedProfileId**: attach only if your app has multiple profiles under one account (family streaming, kid profiles).

### Offer personalization

- Set `setIsOfferPersonalized(true)` only if the price was chosen by automated decision making for this user. EU regulation requires a disclosure, which Google Play renders for you.
- Default is `false`. Do not set `true` for uniform promotional pricing.

### Offer token selection (subscriptions)

Group offers by base plan, then pick the best eligible offer. Google already filters offers the user cannot redeem.

```kotlin
val offersByPlan = productDetails
    .subscriptionOfferDetails
    ?.groupBy { it.basePlanId }
    ?: emptyMap()

val chosenOffer = offersByPlan[selectedBasePlanId]
    ?.firstOrNull() ?: return
```

Whatever the user tapped in your UI must map to the exact `offerToken` you pass. Show the first `pricingPhases` entry (free trial, intro price) in the UI and the recurring phase after it.

### Backend contract

Decide whether acknowledge and grant happen server side (primary) or client side (fallback). Server side keeps verify, grant, and acknowledge in one transaction. Keep client side as a fallback when the server is unreachable.

## Phase 3: Execute

### Build params for a one time product

```kotlin
val productDetailsParams = BillingFlowParams.ProductDetailsParams
    .newBuilder()
    .setProductDetails(productDetails)
    // offerToken is nullable on OneTimePurchaseOfferDetails. selectedOffer is the entry the user chose from
    // productDetails.oneTimePurchaseOfferDetailsList; fail fast rather than silently buying the default purchase option.
    .setOfferToken(requireNotNull(selectedOffer.offerToken))
    .build()

val flowParams = BillingFlowParams.newBuilder()
    .setProductDetailsParamsList(listOf(productDetailsParams))
    .setObfuscatedAccountId(hashUserId(currentUser.id))
    .build()
```

### Build params for a subscription

```kotlin
val productDetailsParams = BillingFlowParams.ProductDetailsParams
    .newBuilder()
    .setProductDetails(productDetails)
    .setOfferToken(chosenOffer.offerToken)
    .build()

val flowParams = BillingFlowParams.newBuilder()
    .setProductDetailsParamsList(listOf(productDetailsParams))
    .build()
```

### Launch the flow

```kotlin
val result = billingClient.launchBillingFlow(activity, flowParams)
if (result.responseCode != BillingResponseCode.OK) {
    handleLaunchError(result)
}
```

You must pass the current `Activity`. `OK` here means the dialog was shown, not that payment succeeded. The real result arrives in `PurchasesUpdatedListener`.

### Handle launch response codes

| Code | Meaning | Action |
|---|---|---|
| `OK` | Dialog shown | Wait for listener callback. |
| `ITEM_ALREADY_OWNED` | User owns product or has unacknowledged purchase | Refresh via `queryPurchasesAsync()` and process it. |
| `DEVELOPER_ERROR` | Bad params, missing offer token, wrong package name | Fix params, check Console listing. |
| `FEATURE_NOT_SUPPORTED` | Device or Play Store does not support the product type | Hide the buy button on this device. |
| `BILLING_UNAVAILABLE` | Billing unavailable for this user or device: outdated Play Store, unsupported country, purchases disabled by an admin, payment method cannot be charged, or (PBL 9+) Play Store blocked by the system such as kids mode | Do not auto retry. Show a generic message with a Try again button. |
| `ITEM_UNAVAILABLE` | Not available in region or deactivated | Check Console availability. |
| `NETWORK_ERROR` | Cannot reach Play servers | Retry after delay, do not loop aggressively. |

### Receive purchase results

```kotlin
val listener = PurchasesUpdatedListener { result, purchases ->
    when (result.responseCode) {
        BillingResponseCode.OK ->
            purchases?.forEach { handlePurchase(it) }
        BillingResponseCode.USER_CANCELED -> Unit
        BillingResponseCode.ITEM_ALREADY_OWNED ->
            refreshPurchases()
        else -> handleError(result)
    }
}
```

### Process a successful purchase (5 steps)

1. **Verify server side.** Post `purchase.purchaseToken` to your backend. Backend calls `purchases.products.get` (one time) or `purchases.subscriptionsv2.get` (subs). For one time products check `purchaseState == 0` (Purchased), `productId`, and that `orderId` was not seen before. For subscriptions check `subscriptionState` (`SUBSCRIPTION_STATE_ACTIVE` for a completed new purchase), each `lineItems[].productId`, and `lineItems[].expiryTime` (RFC 3339).
2. **Check `purchase.purchaseState`.** Grant only on `PURCHASED`. Show pending UI on `PENDING`. Log on `UNSPECIFIED_STATE`.
3. **Grant entitlement idempotently.** Use `purchaseToken` as a unique key. A retry, an RTDN, and a second device query must not stack grants.
4. **Acknowledge or consume within 3 days.**

   ```kotlin
   // Non consumable and subscriptions
   val ackParams = AcknowledgePurchaseParams.newBuilder()
       .setPurchaseToken(purchase.purchaseToken)
       .build()
   billingClient.acknowledgePurchase(ackParams) { r -> /* check OK */ }
   ```

   ```kotlin
   // Consumable
   val consumeParams = ConsumeParams.newBuilder()
       .setPurchaseToken(purchase.purchaseToken)
       .build()
   billingClient.consumeAsync(consumeParams) { r, t -> /* check OK */ }
   ```

   Prefer server side acknowledgement. Fall back to client side only after retries fail.
5. **Notify the user.** Show specific confirmation ("You now have Premium") immediately from the client. For subs, show next billing date and a link to `https://play.google.com/store/account/subscriptions`. Return the user to the content they were trying to unlock.

### Handle pending transactions

```kotlin
fun handlePurchase(purchase: Purchase) {
    when (purchase.purchaseState) {
        Purchase.PurchaseState.PENDING -> {
            showPendingMessage(purchase)
            return
        }
        Purchase.PurchaseState.PURCHASED -> {
            verifyAndGrantAccess(purchase) // idempotent, keyed by purchaseToken
            if (!purchase.isAcknowledged) acknowledge(purchase)
        }
    }
}
```

Transitions arrive via a later `PurchasesUpdatedListener` fire, an RTDN on your server, or a fresh `queryPurchasesAsync()`.

### Call queryPurchasesAsync at the right moments

- **On connect**: right after `startConnection()` succeeds. Catches cross device purchases and reinstalls.
- **On app launch**: keeps local entitlement cache honest against refunds and expirations.
- **On foreground resume**: catches cancellations in Play Store and pending purchases that completed in the background.

### Subscriptions with add ons

Add several subscription `ProductDetailsParams` (each with an offer token); the first is the base item. All items must be auto renewing base plans with the same billing period and unique product IDs, at most 50 items (not available in KR). One purchase token covers the bundle: acknowledge once, then iterate `purchase.products` to grant every item.

## Phase 4: Verify

Prove the flow works before calling it done.

- [ ] `launchBillingFlow()` returns `OK` for a real product in an internal test track.
- [ ] `PurchasesUpdatedListener` fires with `OK` and a non null `purchases` list on success, and with `USER_CANCELED` when the user dismisses the dialog.
- [ ] Every branch in the response code table above has a code path and a log line.
- [ ] Server side verification runs before `grantEntitlement`. Granting twice with the same token produces the same result (idempotency test).
- [ ] Every `PURCHASED` purchase is acknowledged or consumed within 3 days. Monitor unacknowledged count.
- [ ] A test with a delayed payment method (use the tester card or a convenience store flow in a test region) surfaces a pending state and does not grant access.
- [ ] A subscription purchase without `setOfferToken` returns `DEVELOPER_ERROR` (negative test) and your code surfaces it cleanly.
- [ ] `queryPurchasesAsync()` is wired to connect, app launch, and `onResume`.
- [ ] For multi line bundles, `purchase.products` yields every product id and each gets an entitlement.

## References

- [Full chapter](https://www.revenuecat.com/guides/google-play-billing/the-purchase-flow)
