---
name: pbl-v7-to-v8-migration
description: Use this skill when migrating an Android app from Play Billing Library 7.x to 8.x (latest 8.3.0). Covers the full breaking change list, the dependency bump, the required API replacements, the minSdk 23 floor from 8.1, and the step by step verification flow.
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

State that the migration is mechanical rather than architectural. The billing flow, backend integration, and product catalog stay the same. You are replacing the methods PBL 8 deleted, updating one listener signature, and adopting a few new builder options.

If the goal is to land on the current major (PBL 9), use [pbl-v7-to-v9-migration](../pbl-v7-to-v9-migration/) instead. It runs this same v7 to v8 work first, then applies the v8 to v9 delta. The PBL 7 deadline for new apps and updates (August 31, 2026) has already passed, and PBL 8 itself stops accepting new app and update submissions on August 31, 2027, so prefer going straight to v9 unless you have a reason to stop at 8.

## Phase 1: Discovery

Gather the facts before changing anything.

1. **Locate the dependency.** Open `build.gradle`, `build.gradle.kts`, or `libs.versions.toml` and find `com.android.billingclient:billing`. Record the current version string.
2. **Confirm the effective version.** If the version string reads `7.x.x`, treat the baseline as PBL 7. Google documents upgrading from 6 or 7 straight to 8. For a 5.x or 6.x baseline, also apply the rows marked "removed in 7.0.0" in Phase 2. A 5.x baseline also needs the removals Google lists for 6.0.0: replace `queryPurchases()` with `queryPurchasesAsync(QueryPurchasesParams, ...)` and remove the price change confirmation flow (see [price-changes](../price-changes/)).
3. **Scan for removed APIs.** Run a repository wide search for every identifier in the tables in Phase 2. Record every hit. Each hit is a site you must update.
4. **Check SDK levels and Kotlin.** PBL 8.1 and later require `minSdk` 23 (the manifest merger fails below it). If the project uses `billing-ktx`, 8.1 and later also need the Kotlin Gradle plugin at 2.1 or newer. Note the current values; you will bump them in Phase 3 if needed.
5. **Note alternative billing usage.** Grep for `enableAlternativeBilling`, `AlternativeBillingListener`, and `AlternativeChoiceDetails`. These were removed in PBL 7.0.0, so they only appear in a 5.x or 6.x baseline; if any hit, the rename in Step 6 applies.

Report back: "You are on PBL [current]. I found [N] call sites to migrate across [M] files. Planning a direct migration to PBL 8.3.0."

## Phase 2: Plan

Build the checklist. Every item maps to a breaking change from appendix D.

### Removed and changed APIs

| Area | PBL 7 (removed or changed in 8.0.0) | PBL 8 replacement |
|---|---|---|
| Purchase history | `queryPurchaseHistoryAsync()` | `queryPurchasesAsync()` (no history replacement on client) |
| Product queries | `querySkuDetailsAsync()` | `queryProductDetailsAsync()` |
| Purchases query | `queryPurchasesAsync(String, listener)` | `queryPurchasesAsync(QueryPurchasesParams, listener)` |
| Pending purchases | `enablePendingPurchases()` (no args) | `enablePendingPurchases(PendingPurchasesParams)` |
| Product details callback | `onProductDetailsResponse(BillingResult, List<ProductDetails>)` | `onProductDetailsResponse(BillingResult, QueryProductDetailsResult)` |
| Account ID extra | `BillingFlowParams.EXTRA_PARAM_KEY_ACCOUNT_ID` | none; pass the account with `BillingFlowParams.Builder.setObfuscatedAccountId()` |

Recommended in the same pass, not forced by the compiler:

| Area | Before | PBL 8 replacement |
|---|---|---|
| Service reconnection | Manual retry loop | `enableAutoServiceReconnection()` |
| Replacement mode (8.1+) | `SubscriptionUpdateParams.Builder.setSubscriptionReplacementMode()` (deprecated in 8.1, still compiles) | `ProductDetailsParams.Builder.setSubscriptionProductReplacementParams()`; keep `SubscriptionUpdateParams.setOldPurchaseToken()` |

Only for a 5.x or 6.x baseline (removed in 7.0.0, so a 7.x codebase has none of them):

| Area | PBL 6 (removed in 7.0.0) | Replacement |
|---|---|---|
| Alternative billing toggle | `enableAlternativeBilling()` | `enableUserChoiceBilling()` |
| Alternative billing listener | `AlternativeBillingListener` | `UserChoiceBillingListener` |
| Alternative choice details | `AlternativeChoiceDetails` | `UserChoiceDetails` |
| Alternative choice product | `AlternativeChoiceDetails.Product` | `UserChoiceDetails.Product` |
| Proration enum | `ProrationMode` | `SubscriptionUpdateParams.ReplacementMode` |
| Proration setter | `setReplaceProrationMode()`, `setReplaceSkusProrationMode()` | `setSubscriptionReplacementMode()` |
| Old token setter | `setOldSkuPurchaseToken()` | `setOldPurchaseToken()` |

### ProrationMode to ReplacementMode constant map (5.x or 6.x baseline)

| `ProrationMode` (PBL 6 and lower) | `SubscriptionUpdateParams.ReplacementMode` |
|---|---|
| `IMMEDIATE_WITH_TIME_PRORATION` | `WITH_TIME_PRORATION` |
| `IMMEDIATE_AND_CHARGE_PRORATED_PRICE` | `CHARGE_PRORATED_PRICE` |
| `IMMEDIATE_AND_CHARGE_FULL_PRICE` | `CHARGE_FULL_PRICE` |
| `IMMEDIATE_WITHOUT_PRORATION` | `WITHOUT_PRORATION` |
| `DEFERRED` | `DEFERRED` |

`KEEP_EXISTING` (PBL 8.1+) exists only in the product level `SubscriptionProductReplacementParams.ReplacementMode`, whose integer values differ from `SubscriptionUpdateParams.ReplacementMode` for the same names (see Step 8).

Present the plan to the user as a checklist and confirm before editing files.

## Phase 3: Execute

Work through the steps in order. Each step lifts a block from appendix D.

### Step 1: Bump the dependency

Update the version string to the latest stable PBL 8 release, 8.3.0. It includes 8.1 (`SubscriptionProductReplacementParams`, `includeSuspendedSubscriptions`, pre orders), 8.2.1 (the billing program APIs), and 8.3 (external payments).

```gradle
implementation("com.android.billingclient:billing-ktx:8.3.0")
```

From 8.1, set `minSdk` to 23, and with `billing-ktx` use the Kotlin Gradle plugin 2.1 or newer (`billing-ktx` 8.1+ is compiled with Kotlin 2.2 metadata, which Kotlin 2.0 cannot read).

Sync Gradle. Expect compile errors. They guide the rest of this phase.

### Step 2: Fix the `BillingClient` builder

Replace the parameterless `enablePendingPurchases()` with the params object. Add `enableAutoServiceReconnection()` in the same builder chain.

```kotlin
val billingClient = BillingClient.newBuilder(context)
    .setListener(purchasesUpdatedListener)
    .enablePendingPurchases(
        PendingPurchasesParams.newBuilder()
            .enableOneTimeProducts()
            // .enablePrepaidPlans() // optional, see below
            .build()
    )
    .enableAutoServiceReconnection()
    .build()
```

`enableOneTimeProducts()` is mandatory: `build()` throws "Pending purchases for one-time products must be supported." without it, and it is exactly what the old parameterless call did. `enablePrepaidPlans()` is optional and changes behavior: add it only if the app sells prepaid plans and handles pending prepaid purchases (no entitlement until the purchase is `PURCHASED`).

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

If the app needs historical purchase data, move that lookup to the backend: record consumed purchases as you verify them, and use the Voided Purchases API (`purchases.voidedpurchases.list`) for refunds and revocations. If history was used to decide free trial eligibility, rely on the offers `queryProductDetailsAsync()` returns: Play only returns offers the user is eligible for.

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

### Step 5: Switch to the `QueryProductDetailsResult` callback

PBL 8 still delivers product details through a listener, but its second parameter changed from a `List<ProductDetails>` to a `QueryProductDetailsResult`, which also lists the products Play could not return.

```kotlin
billingClient.queryProductDetailsAsync(params) { billingResult, queryProductDetailsResult ->
    if (billingResult.responseCode == BillingResponseCode.OK) {
        queryProductDetailsResult.productDetailsList.forEach { displayProduct(it) }
        queryProductDetailsResult.unfetchedProductList.forEach { logUnfetchedProduct(it) }
    }
}
```

Read `unfetchedProductList` during the same pass. Each `UnfetchedProduct` carries a `productId`, a `productType`, and a `statusCode` (`UnfetchedProduct.StatusCode`: `PRODUCT_NOT_FOUND`, `NO_ELIGIBLE_OFFER`, `INVALID_PRODUCT_ID_FORMAT`, `UNKNOWN`), which you should log for diagnostics. The `billing-ktx` `queryProductDetails()` suspend function returns only `billingResult` and `productDetailsList`; use the listener form when you need the unfetched products.

### Step 6: Rename alternative billing to user choice billing (5.x or 6.x baseline only)

A 7.x codebase cannot contain the old names, because PBL 7.0.0 removed them. If Phase 1 found hits, the baseline is older; apply the rename everywhere the grep found a hit.

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

### Step 7: Replace `ProrationMode` with `ReplacementMode` (5.x or 6.x baseline only)

Use the constant map in Phase 2. Update the setter name from `setReplaceProrationMode` to `setSubscriptionReplacementMode`.

```kotlin
val updateParams = BillingFlowParams.SubscriptionUpdateParams.newBuilder()
    .setOldPurchaseToken(oldToken)
    .setSubscriptionReplacementMode(
        BillingFlowParams.SubscriptionUpdateParams.ReplacementMode.CHARGE_PRORATED_PRICE
    )
    .build()
```

On 8.1+ this setter is deprecated; Step 8 shows the replacement.

### Step 8: Move the replacement mode to `SubscriptionProductReplacementParams` (PBL 8.1)

When targeting 8.1 or later, set the replacement mode per product on `ProductDetailsParams`. The old purchase token still goes on `SubscriptionUpdateParams`.

```kotlin
val productDetailsParams = BillingFlowParams.ProductDetailsParams.newBuilder()
    .setProductDetails(newProductDetails)
    .setOfferToken(offerToken)
    .setSubscriptionProductReplacementParams(
        BillingFlowParams.ProductDetailsParams.SubscriptionProductReplacementParams.newBuilder()
            .setOldProductId(oldProductId)
            .setReplacementMode(
                BillingFlowParams.ProductDetailsParams.SubscriptionProductReplacementParams
                    .ReplacementMode.CHARGE_PRORATED_PRICE
            )
            .build()
    )
    .build()

val billingFlowParams = BillingFlowParams.newBuilder()
    .setProductDetailsParamsList(listOf(productDetailsParams))
    .setSubscriptionUpdateParams(
        BillingFlowParams.SubscriptionUpdateParams.newBuilder()
            .setOldPurchaseToken(oldToken) // still required
            .build()
    )
    .build()
```

Delete any `setSubscriptionReplacementMode()` call when you add product level params: if both are set, `launchBillingFlow()` returns `DEVELOPER_ERROR` (debug message "...cannot be called at the same time."). Use the product level `ReplacementMode` constants only: its integer values differ from `SubscriptionUpdateParams.ReplacementMode` (`CHARGE_FULL_PRICE` is 4 instead of 5, `DEFERRED` is 5 instead of 6, and 6 means `KEEP_EXISTING`), so a constant taken from the old interface silently selects the wrong mode. See [plan-changes](../plan-changes/).

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

This also returns suspended subscriptions: ones the user paused, or whose renewal payment was declined and that are now on account hold. Grace period subscriptions are still active and are returned without this flag. For any purchase with `isSuspended()` true, do not grant access; send the user to the Play subscriptions center to fix the payment method or resume.

### Step 12: Review ProGuard / R8 rules

Update any custom keep rules that name classes or methods PBL 8 removed.

## Phase 4: Verify

Prove the migration works before handing back.

1. **Clean compile.** Run `./gradlew clean assembleDebug`. Resolve any remaining references to removed APIs. A manifest merger error about `minSdkVersion` means `minSdk` is still below 23.
2. **Unit tests.** Run `./gradlew test`. Fix any tests that stub the old listener shapes or replacement mode constants.
3. **Lifecycle tests on a real device with the latest Play Store.** Exercise these flows:
   - New subscription purchase
   - Subscription renewal
   - Upgrade and downgrade plan changes using the product level replacement params
   - One time product purchase and consumption
   - Pending purchase completion
4. **License testing accounts.** Use a license tester to repeat the flows without real charges. Pay attention to plan changes because the replacement mode constants are the riskiest site.
5. **Auto reconnection smoke test.** Sever the real binding while the app holds a connected `BillingClient`, for example by force stopping the Play Store app (`adb shell am force-stop com.android.vending`). Confirm your `onBillingServiceDisconnected()` log fires, so you know the binding actually dropped. Then call `queryPurchasesAsync()` and confirm it returns `OK` without your code calling `startConnection()`. The Play Billing Lab Response Simulator cannot run this check (it never drops the binding), and airplane mode only produces `NETWORK_ERROR`.
6. **Unfetched product check.** Temporarily add a bogus product ID to a query call. Confirm it appears in `unfetchedProductList` with a `statusCode`.
7. **Internal test track rollout.** Publish to the internal track first. Monitor crash reports and billing success rates for at least one full billing cycle before promoting to production.

Report back a final summary: the old version, the new version, every change applied, new features adopted, and the verification evidence.

## References

- [Full chapter](https://www.revenuecat.com/guides/google-play-billing/appendix-migrating-from-pbl-7-to-pbl-8)

- Upstream deadlines: PBL 7 last accepted new apps and updates on August 31, 2026 (extension window through November 1, 2026). PBL 8 is accepted until August 31, 2027.
