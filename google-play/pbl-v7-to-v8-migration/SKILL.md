---
name: pbl-v7-to-v8-migration
description: Use this skill when migrating an Android app from Play Billing Library 7.x to 8.x. Covers the full breaking change list, the dependency bump, the required API renames, and the step by step verification flow.
license: Apache-2.0; see LICENSE
metadata:
  author: RevenueCat
  source: google-play-handbook appendix D
  keywords:
  - android
  - play-billing
  - pbl8
  - migration
  - breaking-changes
---

## Phase 0: Intent

Announce to the user: "I will migrate this project from PBL 7 to PBL 8."

State that the migration is mechanical rather than architectural. The billing flow, backend integration, and product catalog stay the same. You are renaming classes, updating method signatures, and removing calls that PBL 8 deleted.

If the goal is to land on the current major (PBL 9), use [pbl-v7-to-v9-migration](../pbl-v7-to-v9-migration/) instead. It runs this same v7 to v8 work first, then applies the small v8 to v9 delta. PBL 8 itself stops accepting new app and update submissions on August 31, 2027, so prefer going straight to v9 unless you have a reason to stop at 8.

## Phase 1: Discovery

Gather the facts before changing anything.

1. **Locate the dependency.** Open `build.gradle`, `build.gradle.kts`, or `libs.versions.toml` and find `com.android.billingclient:billing`. Record the current version string.
2. **Confirm the effective version.** If the version string reads `7.x.x`, treat the baseline as PBL 7. If the string is older (for example `5.x` or `6.x`) but the code still compiles against PBL 7 APIs, also treat the baseline as PBL 7 for this skill. You can migrate directly from 5 or 6 to 8 by following the same steps.
3. **Scan for deprecated APIs.** Run a repository wide search for every identifier in the rename map in Phase 2. Record every hit. Each hit is a site you must update.
4. **Check compile SDK.** PBL 8 expects a recent `compileSdk`. Read `build.gradle` and note the value. You will bump it in Phase 3 if needed.
5. **Note alternative billing usage.** Grep for `enableAlternativeBilling`, `AlternativeBillingListener`, and `AlternativeChoiceDetails`. If any hit, the alternative billing rename block in Phase 3 applies.

Report back: "You are on PBL [current]. I found [N] deprecated call sites across [M] files. Planning a direct migration to PBL 8.1."

## Phase 2: Plan

Build the checklist. Every item maps to a breaking change from appendix D.

### Removed and changed APIs

| Area | PBL 7 (removed or changed) | PBL 8 replacement |
|---|---|---|
| Purchase history | `queryPurchaseHistoryAsync()` | `queryPurchasesAsync()` (no history replacement on client) |
| Product queries | `querySkuDetailsAsync()` | `queryProductDetailsAsync()` |
| Pending purchases | `enablePendingPurchases()` (no args) | `enablePendingPurchases(PendingPurchasesParams)` |
| Product details result | `ProductDetailsResponseListener` returning `List<ProductDetails>` | `QueryProductDetailsResult` return value |
| Alternative billing toggle | `enableAlternativeBilling()` | `enableUserChoiceBilling()` |
| Alternative billing listener | `AlternativeBillingListener` | `UserChoiceBillingListener` |
| Alternative choice details | `AlternativeChoiceDetails` | `UserChoiceDetails` |
| Alternative choice product | `AlternativeChoiceDetails.Product` | `UserChoiceDetails.Product` |
| Proration enum | `ProrationMode` | `ReplacementMode` |
| Proration setter | `setReplaceProrationMode()` | `setSubscriptionReplacementMode()` |
| Subscription update params | `SubscriptionUpdateParams` | `SubscriptionProductReplacementParams` (PBL 8.1) |
| Service reconnection | Manual retry loop | `enableAutoServiceReconnection()` |

### ProrationMode to ReplacementMode constant map

| `ProrationMode` (PBL 7) | `ReplacementMode` (PBL 8) |
|---|---|
| `IMMEDIATE_WITH_TIME_PRORATION` | `WITH_TIME_PRORATION` |
| `IMMEDIATE_AND_CHARGE_PRORATED_PRICE` | `CHARGE_PRORATED_PRICE` |
| `IMMEDIATE_AND_CHARGE_FULL_PRICE` | `CHARGE_FULL_PRICE` |
| `IMMEDIATE_WITHOUT_PRORATION` | `WITHOUT_PRORATION` |
| `DEFERRED` | `DEFERRED` |
| (none) | `KEEP_EXISTING` (PBL 8.1+) |

Present the plan to the user as a checklist and confirm before editing files.

## Phase 3: Execute

Work through the steps in order. Each step lifts a block from appendix D.

### Step 1: Bump the dependency

Update the version string to the latest stable PBL 8 release. Target 8.1 or later so you get `SubscriptionProductReplacementParams` and `includeSuspendedSubscriptions` in the same pass.

```gradle
implementation("com.android.billingclient:billing-ktx:8.1.0")
```

Sync Gradle. Expect compile errors. They guide the rest of this phase.

### Step 2: Fix the `BillingClient` builder

Replace the parameterless `enablePendingPurchases()` with the params object. Add `enableAutoServiceReconnection()` in the same builder chain.

```kotlin
val billingClient = BillingClient.newBuilder(context)
    .setListener(purchasesUpdatedListener)
    .enablePendingPurchases(
        PendingPurchasesParams.newBuilder()
            .enableOneTimeProducts()
            .enablePrepaidPlans()
            .build()
    )
    .enableAutoServiceReconnection()
    .build()
```

You must call at least one of `enableOneTimeProducts()` or `enablePrepaidPlans()`. Call both if the app sells both.

### Step 3: Replace `queryPurchaseHistoryAsync`

PBL 8 removed this method. The replacement is `queryPurchasesAsync`, which returns active purchases only.

```kotlin
val result = billingClient.queryPurchasesAsync(
    QueryPurchasesParams.newBuilder()
        .setProductType(ProductType.SUBS)
        .build()
)
result.purchasesList.forEach { purchase -> handle(purchase) }
```

If the app needs historical purchase data for analytics, move that lookup to the backend through the Google Play Developer API (`Purchases.subscriptionsv2` or `Purchases.products`).

### Step 4: Replace `querySkuDetailsAsync`

Switch to `queryProductDetailsAsync` with the product based params builder.

```kotlin
val params = QueryProductDetailsParams.newBuilder()
    .setProductList(listOf(
        QueryProductDetailsParams.Product.newBuilder()
            .setProductId("premium_monthly")
            .setProductType(ProductType.SUBS)
            .build()
    )).build()
```

Update downstream display code. `SkuDetails.price` is gone. `ProductDetails` exposes `subscriptionOfferDetails`, base plans, and pricing phases.

### Step 5: Switch to the `QueryProductDetailsResult` return value

PBL 8 returns a result object instead of invoking a listener with a nullable list.

```kotlin
val result = billingClient.queryProductDetailsAsync(params)
if (result.billingResult.responseCode == BillingResponseCode.OK) {
    result.productDetailsList.forEach { displayProduct(it) }
    result.unfetchedProductList.forEach { logUnfetchedProduct(it) }
}
```

Read `unfetchedProductList` during the same pass. Each `UnfetchedProduct` carries a `productId` and `reason`, which you should log for diagnostics.

### Step 6: Rename alternative billing to user choice billing

Apply the rename everywhere the grep from Phase 1 found a hit.

```kotlin
.enableUserChoiceBilling(
    UserChoiceBillingListener { details ->
        val products = details.products
        val token = details.externalTransactionToken
        handleUserChoiceBilling(products, token)
    }
)
```

The callback payload shape is unchanged. Only the names move.

### Step 7: Replace `ProrationMode` with `ReplacementMode`

Use the constant map in Phase 2. Update the setter name from `setReplaceProrationMode` to `setSubscriptionReplacementMode`.

```kotlin
val updateParams = BillingFlowParams.SubscriptionUpdateParams.newBuilder()
    .setOldPurchaseToken(oldToken)
    .setSubscriptionReplacementMode(ReplacementMode.CHARGE_PRORATED_PRICE)
    .build()
```

### Step 8: Migrate to `SubscriptionProductReplacementParams` (PBL 8.1)

When targeting 8.1 or later, move the replacement configuration off `BillingFlowParams` and onto `ProductDetailsParams`.

```kotlin
val replacementParams = BillingFlowParams
    .SubscriptionProductReplacementParams.newBuilder()
    .setOldPurchaseToken(oldToken)
    .setReplacementMode(ReplacementMode.CHARGE_PRORATED_PRICE)
    .build()
```

Attach `replacementParams` to the product params through `setSubscriptionReplacementParams(replacementParams)`.

### Step 9: Simplify reconnection logic

With `enableAutoServiceReconnection()` set in Step 2, remove manual `startConnection()` retries from `onBillingServiceDisconnected()`. Keep the callback for logging or a reconnecting UI hint if you want one.

### Step 10: Adopt sub response codes (optional)

Inside `PurchasesUpdatedListener`, read `billingResult.getOnPurchasesUpdatedSubResponseCode()` for a finer grained failure reason (for example insufficient funds).

### Step 11: Opt in to `includeSuspendedSubscriptions` (PBL 8.1, optional)

```kotlin
val params = QueryPurchasesParams.newBuilder()
    .setProductType(ProductType.SUBS)
    .includeSuspendedSubscriptions(true)
    .build()
```

This surfaces account hold and grace period subscriptions on the client so you can prompt for a payment update without waiting on a backend signal.

### Step 12: Review ProGuard / R8 rules

PBL 8 ships different class names. Update any keep rules that referenced removed classes (`SkuDetails`, `AlternativeBillingListener`, and friends).

## Phase 4: Verify

Prove the migration works before handing back.

1. **Clean compile.** Run `./gradlew clean assembleDebug`. Resolve any remaining references to removed APIs.
2. **Unit tests.** Run `./gradlew test`. Fix any tests that stub the old listener shapes or proration constants.
3. **Lifecycle tests on a real device with the latest Play Store.** Exercise these flows:
   - New subscription purchase
   - Subscription renewal
   - Upgrade and downgrade plan changes using the new `ReplacementMode`
   - One time product purchase and consumption
   - Pending purchase completion
4. **License testing accounts.** Use a license tester to repeat the flows without real charges. Pay attention to plan changes because the proration to replacement rename is the riskiest rename site.
5. **Auto reconnection smoke test.** Toggle airplane mode or force stop the Play Store app to sever the connection. Confirm the billing client reconnects without a manual `startConnection()` call.
6. **Unfetched product check.** Temporarily add a bogus product ID to a query call. Confirm it appears in `result.unfetchedProductList` with a reason.
7. **Internal test track rollout.** Publish to the internal track first. Monitor crash reports and billing success rates for at least one full billing cycle before promoting to production.

Report back a final summary: the old version, the new version, every rename applied, new features adopted, and the verification evidence.

## References

- [Full chapter](https://www.revenuecat.com/guides/google-play-billing/appendix-migrating-from-pbl-7-to-pbl-8)

- Upstream deadline to track: PBL 7 support ends August 31, 2026. Aim to be in production on PBL 8 by June 2026 to leave room for two full billing cycles of monitoring.
