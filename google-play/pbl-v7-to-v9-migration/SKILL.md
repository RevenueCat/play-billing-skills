---
name: pbl-v7-to-v9-migration
description: "Use this skill when migrating an Android app from Play Billing Library 7.x to 9.x (latest 9.1.0). Google documents the 7 to 9 upgrade as one hop; this skill still runs it as two compile checkpoints, the v8.0.0 removals first and then the v9 delta. Covers the full removal map, the dependency bumps, the SDK and Kotlin floors, the two stage plan, and the verification flow."
license: Apache-2.0; see LICENSE
metadata:
  author: RevenueCat
  source: Google Play Billing Library v9 migration guide and release notes; google-play-handbook appendix D; RevenueCat Play Billing v9 deep dive
  keywords:
  - android
  - play-billing
  - pbl9
  - migration
  - breaking-changes
---

## Phase 0: Intent

Announce to the user: "I will migrate this project from PBL 7 to PBL 9 in two stages."

State the structure clearly. Google's v9 migration guide covers upgrading from PBL 7 straight to 9, and a single dependency bump to 9.1.0 is a valid path. This skill still splits the code work into two stages with a v8 compile checkpoint between them, so the large v8 rework is compiled and tested before the v9 changes land on top.

- **Stage A, v7 to v8:** the bulk of the work. PBL 8.0.0 removed `querySkuDetailsAsync`, `queryPurchaseHistoryAsync`, the `String` overload of `queryPurchasesAsync`, and the parameterless `enablePendingPurchases()`, and changed `onProductDetailsResponse` to receive a `QueryProductDetailsResult`. PBL 8.1 raised `minSdk` to 23.
- **Stage B, v8 to v9:** the smaller delta. PBL 9.0.0 deleted the leftover deprecated types (`BillingClient.SkuType`, `SkuDetails`, `SkuDetailsParams`, `SkuDetailsResponseListener`, `QueryPurchaseHistoryParams`, `setSkuDetails()`), needs `compileSdk` 35, and changed two behaviors.

The proration and alternative billing renames are not part of this migration. PBL 7.0.0 already removed `ProrationMode`, `setOldSkuPurchaseToken()`, `enableAlternativeBilling()`, `AlternativeBillingListener`, and `AlternativeChoiceDetails`, so code that compiles against v7 cannot contain them. They only apply to a 5.x or 6.x baseline (see the note under Stage A).

This skill is self contained, but each stage links to the dedicated single hop skill if you want the long form: [pbl-v7-to-v8-migration](../pbl-v7-to-v8-migration/) and [pbl-v8-to-v9-migration](../pbl-v8-to-v9-migration/).

Urgency: **the PBL 7 deadline for new apps and app updates was August 31, 2026, and it has passed.** A v7 app can ship updates only if it was granted the extension in Play Console, and only until November 1, 2026. After that, no release built on v7 (including security fixes) can be uploaded. Treat this migration as release blocking.

## Phase 1: Discovery

1. **Locate the dependency.** Find `com.android.billingclient:billing` or `billing-ktx` in `build.gradle(.kts)` or `libs.versions.toml`. Confirm it reads `7.x`. If it reads `5.x` or `6.x`, also apply the 7.0.0 renames listed under Stage A. A 5.x baseline also needs the removals Google lists for 6.0.0: replace `queryPurchases()` with `queryPurchasesAsync(QueryPurchasesParams, ...)` and remove the price change confirmation flow (see [price-changes](../price-changes/)).
2. **Scan for every removed identifier.** Grep the repo for each item in the Stage A and Stage B tables below. Record every hit; each is an edit site.
3. **Check SDK levels and Kotlin.** Read `minSdk`, `compileSdk`, `targetSdk`, and the Kotlin Gradle plugin version. You will move `minSdk` to 23 (required from PBL 8.1) and `compileSdk` to 35 (required by PBL 9). With `billing-ktx`, the Kotlin Gradle plugin must reach 2.1 for Stage A (8.1+) and 2.2 for Stage B (9.x). `targetSdk` is not driven by PBL: Play's target API level policy has required API 36 for new apps and app updates since August 31, 2026, so flag a lower value to the user as a separate release blocker.
4. **Check for a pinned androidx.core.** Stage B's blocked store reclassification needs androidx.core 1.9+. PBL 9 pulls 1.15.0 transitively, so only a `force` or `strictly` constraint below 1.9 breaks it.
5. **Note alternative billing usage.** Grep for `enableUserChoiceBilling`, `enableAlternativeBillingOnly`, `enableExternalOffer`, and `DeveloperProvidedBillingDetails`. The external offer APIs (`enableExternalOffer`, `isExternalOfferAvailableAsync`, `createExternalOfferReportingDetailsAsync`, `showExternalOfferInformationDialog`) still compile on 9.1 but have been deprecated since 8.2.0; plan their replacement with [alternative-billing](../alternative-billing/), outside this migration.

Report back: "You are on PBL [current]. I found [N] call sites to migrate across [M] files. Planning a two stage migration: v7 to v8.3.0, then v8 to v9.1.0."

## Phase 2: Plan

### Stage A: v7 to v8 removals

Every item here was removed in **PBL 8.0.0**. (Full depth: [pbl-v7-to-v8-migration](../pbl-v7-to-v8-migration/).)

| Area | PBL 7 (removed in 8.0.0) | PBL 8 replacement |
|---|---|---|
| Product queries | `querySkuDetailsAsync()` | `queryProductDetailsAsync()` |
| Product details callback | `onProductDetailsResponse(BillingResult, List<ProductDetails>)` | `onProductDetailsResponse(BillingResult, QueryProductDetailsResult)` |
| Purchase history | `queryPurchaseHistoryAsync()` | `queryPurchasesAsync(QueryPurchasesParams, ...)` for active and pending purchases; history moves to your backend |
| Purchases query | `queryPurchasesAsync(String, listener)` | `queryPurchasesAsync(QueryPurchasesParams, listener)` |
| Pending purchases | `enablePendingPurchases()` (no args) | `enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())` |
| Account ID extra | `BillingFlowParams.EXTRA_PARAM_KEY_ACCOUNT_ID` | none; pass the account with `BillingFlowParams.Builder.setObfuscatedAccountId()` |

Only for a 5.x or 6.x baseline (these were removed in **PBL 7.0.0**, so a 7.x codebase has none of them):

| PBL 6 (removed in 7.0.0) | Replacement |
|---|---|
| `ProrationMode`, `setReplaceProrationMode()`, `setReplaceSkusProrationMode()` | `SubscriptionUpdateParams.ReplacementMode`, `setSubscriptionReplacementMode()` (see the constant map below) |
| `setOldSkuPurchaseToken()` | `setOldPurchaseToken()` |
| `enableAlternativeBilling()`, `AlternativeBillingListener`, `AlternativeChoiceDetails` | `enableUserChoiceBilling()`, `UserChoiceBillingListener`, `UserChoiceDetails` |

| `ProrationMode` (PBL 6 and lower) | `SubscriptionUpdateParams.ReplacementMode` |
|---|---|
| `IMMEDIATE_WITH_TIME_PRORATION` | `WITH_TIME_PRORATION` |
| `IMMEDIATE_AND_CHARGE_PRORATED_PRICE` | `CHARGE_PRORATED_PRICE` |
| `IMMEDIATE_AND_CHARGE_FULL_PRICE` | `CHARGE_FULL_PRICE` |
| `IMMEDIATE_WITHOUT_PRORATION` | `WITHOUT_PRORATION` |
| `DEFERRED` | `DEFERRED` |

`KEEP_EXISTING` (PBL 8.1+) exists only in `BillingFlowParams.ProductDetailsParams.SubscriptionProductReplacementParams.ReplacementMode`. That interface shares the constant names but not the integer values (`CHARGE_FULL_PRICE` is 5 in `SubscriptionUpdateParams.ReplacementMode` and 4 in the product level one, `DEFERRED` is 6 and 5, and 6 means `KEEP_EXISTING` in the product level one), so always reference a constant through the class whose builder receives it.

### Stage B: v8 to v9 delta

(Full depth: [pbl-v8-to-v9-migration](../pbl-v8-to-v9-migration/).)

| Removed in 9.0.0 | Use instead |
|---|---|
| `BillingClient.SkuType` | `BillingClient.ProductType` (same string values) |
| `SkuDetails` | `ProductDetails` |
| `SkuDetailsParams`, `SkuDetailsResponseListener` | `QueryProductDetailsParams`, `ProductDetailsResponseListener` |
| `BillingFlowParams.Builder.setSkuDetails()` | `setProductDetailsParamsList()` |
| `QueryPurchaseHistoryParams` | see the purchase history row in Stage A |

- Bump the dependency to 9.1.0, `compileSdk` to 35, and Kotlin to 2.2 if you use `billing-ktx`.
- Blocked Play Store now returns `BILLING_UNAVAILABLE` instead of generic `ERROR`.
- `DeveloperProvidedBillingDetails.getLinkUri()` is now `@Nullable` (only if you use developer provided billing).
- Optional: in app messaging for opt in price increases.

Present both stages as one checklist and confirm before editing.

## Phase 3: Execute

Do Stage A end to end, get a clean compile, then do Stage B. Do not interleave: a clean v8 build is the checkpoint that proves the heavy work is done.

### Stage A: migrate to PBL 8

1. **Bump to the latest v8, 8.3.0.** It includes the 8.1 to 8.3 additions (`SubscriptionProductReplacementParams`, `includeSuspendedSubscriptions`, the billing program APIs). From 8.1, `minSdk` must be 23 and `billing-ktx` needs Kotlin 2.1+.

   ```gradle
   implementation("com.android.billingclient:billing-ktx:8.3.0")
   ```

2. **Fix the `BillingClient` builder.** Replace parameterless `enablePendingPurchases()` and add auto reconnection.

   ```kotlin
   BillingClient.newBuilder(context)
       .setListener(purchasesUpdatedListener)
       .enablePendingPurchases(
           PendingPurchasesParams.newBuilder()
               .enableOneTimeProducts() // mandatory, build() throws without it
               // .enablePrepaidPlans() // optional, only if you handle pending prepaid plan purchases
               .build()
       )
       .enableAutoServiceReconnection()
       .build()
   ```

3. **Replace `querySkuDetailsAsync` with `queryProductDetailsAsync`** and switch display code off `SkuDetails` onto `ProductDetails` (base plans, offers, pricing phases). Read `QueryProductDetailsResult.unfetchedProductList` in the same pass. It is only available through the listener API; the `billing-ktx` `queryProductDetails()` result exposes `productDetailsList` but not the unfetched products.
4. **Replace `queryPurchaseHistoryAsync`** with `queryPurchasesAsync` (active and pending only). Move historical lookups to the backend: record consumed purchases as you verify them, and use the Voided Purchases API for refunds and revocations. If history was used for free trial eligibility, rely on the offers `queryProductDetailsAsync()` returns: Play only returns offers the user is eligible for.
5. **5.x or 6.x baseline only:** apply the 7.0.0 renames (alternative billing to user choice billing, `ProrationMode` to `ReplacementMode` with the constant map, `setOldSkuPurchaseToken` to `setOldPurchaseToken`). Skip this step for a true 7.x codebase.
6. **Plan changes on 8.1+.** `setSubscriptionReplacementMode()` is deprecated. Set the mode per product with `ProductDetailsParams.Builder.setSubscriptionProductReplacementParams()` and its own `ReplacementMode` constants, and keep passing the old purchase token with `SubscriptionUpdateParams.setOldPurchaseToken()`. Remove the old `setSubscriptionReplacementMode()` call: setting both makes `launchBillingFlow()` return `DEVELOPER_ERROR`. See [plan-changes](../plan-changes/).
7. **Bump `minSdk` to 23.** Below 23 the manifest merger fails on PBL 8.1+. Review custom ProGuard/R8 keep rules that name removed classes.
8. **Compile clean and run tests.** This is the checkpoint. Resolve every reference to an API removed in 8.0.0 before moving on.

### Stage B: migrate to PBL 9

Only after a clean v8 build, do the v9 delta (full depth: [pbl-v8-to-v9-migration](../pbl-v8-to-v9-migration/)):

1. **Bump the dependency to 9.1.0.**

   ```gradle
   implementation("com.android.billingclient:billing-ktx:9.1.0")
   ```

2. **Replace the types removed in 9.0.0**, usually leftover `BillingClient.SkuType` constants (use `BillingClient.ProductType`).
3. **Raise `compileSdk` to 35** (the build fails in `checkAarMetadata` below it) and, with `billing-ktx`, the Kotlin Gradle plugin to 2.2. `minSdk` stays 23. Leave `targetSdk` to Play's target API policy, not to PBL.
4. **Update blocked store error handling.** Handle `BILLING_UNAVAILABLE` as "billing not available on this device" instead of relying on a generic `ERROR`. Log the "Play Store is blocked" debug message, but do not branch on its text.
5. **Handle nullable `getLinkUri()`** if you use developer provided billing (null and empty string guard before `Uri.parse`).
6. **Optionally adopt in app price increase messaging** via `showInAppMessages`.

## Phase 4: Verify

1. **Clean compile at v8, then at v9.** Two checkpoints. `./gradlew clean assembleDebug` each time.
2. **Unit tests** at both checkpoints (`./gradlew test`). Fix tests that stub old listener shapes or replacement mode constants.
3. **Lifecycle tests on a real device** with the latest Play Store: new subscription, renewal, upgrade/downgrade with the product level replacement params, one time product purchase and consume, pending purchase completion.
4. **License test accounts.** Repeat without real charges. Pay special attention to plan changes; the replacement mode constants are the riskiest site because the two `ReplacementMode` interfaces map the same names to different integers.
5. **Auto reconnection smoke test.** Sever the real binding while the app holds a connected `BillingClient`, for example by force stopping the Play Store app (`adb shell am force-stop com.android.vending`). Confirm your `onBillingServiceDisconnected()` log fires, so you know the binding actually dropped. Then call `queryPurchasesAsync()` and confirm it returns `OK` without your code calling `startConnection()`. The Play Billing Lab Response Simulator cannot run this check (it never drops the binding), and airplane mode only produces `NETWORK_ERROR`.
6. **v9 specific checks.** Blocked store returns `BILLING_UNAVAILABLE`; nullable link URI does not crash; the merged manifest declares `com.google.android.play.billingclient.version` as 9.1.0.
7. **Internal test track rollout.** Monitor crash reports and billing success rates for at least one full billing cycle before promoting to production.

Report back a final summary: the old version, the two stage path taken, every change applied in Stage A, the v9 adjustments in Stage B, and the verification evidence.

## References

- [Full chapter](https://www.revenuecat.com/guides/google-play-billing/appendix-migrating-from-pbl-7-to-pbl-8)
- [Google Play Billing Library v9 migration guide](https://developer.android.com/google/play/billing/migrate-gpblv9)
- [Play Billing Library release notes](https://developer.android.com/google/play/billing/release-notes)
- [RevenueCat Play Billing v9 deep dive](https://www.revenuecat.com/blog/engineering/play-billing-v9/)
- Upstream deadlines: PBL 7 last accepted new apps and updates on August 31, 2026 (extension window through November 1, 2026). PBL 8 does on August 31, 2027, and PBL 9 on August 31, 2028.
