---
name: pbl-v7-to-v9-migration
description: "Use this skill when migrating an Android app from Play Billing Library 7.x straight to 9.x. There is no direct path: you do the breaking v7 to v8 work first, then the small v8 to v9 delta. Covers the full rename map, the dependency bump, the two stage plan, and the verification flow."
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

State the structure clearly. **There is no direct v7 to v9 shortcut.** Almost all of the breaking work belongs to v8.0.0 (the `Sku*` removals, the proration to replacement mode rename, alternative billing renames, the pending purchases params, the `queryProductDetailsAsync` result shape). v9 itself removed nothing and only adds a target SDK bump plus three small adjustments. So this migration is:

- **Stage A — v7 to v8:** the heavy, mechanical rename work.
- **Stage B — v8 to v9:** the small delta.

This skill is self contained, but each stage links to the dedicated single hop skill if you want the long form: [pbl-v7-to-v8-migration](../pbl-v7-to-v8-migration/) and [pbl-v8-to-v9-migration](../pbl-v8-to-v9-migration/).

Urgency: **PBL 7 stops accepting new app and update submissions on August 31, 2026.** After that date you cannot ship any release (including security fixes) built on v7, so plan to be in production on v9 with margin for monitoring.

## Phase 1: Discovery

1. **Locate the dependency.** Find `com.android.billingclient:billing` in `build.gradle(.kts)` or `libs.versions.toml`. Confirm it reads `7.x` (or `5.x`/`6.x` compiling against v7 APIs — the same steps apply).
2. **Scan for every v7 era identifier.** Grep the repo for each item in the Stage A rename map below. Record every hit; each is an edit site.
3. **Check SDK levels.** Read `minSdk`, `compileSdk`, `targetSdk`. You will move `minSdk` to 23 and `targetSdk` to 35 across the migration.
4. **Check androidx.core.** Record the version; Stage B needs 1.9+.
5. **Note alternative billing and developer provided billing usage.** Grep for `enableAlternativeBilling`, `AlternativeBillingListener`, `AlternativeChoiceDetails`, and `DeveloperProvidedBillingDetails`.

Report back: "You are on PBL [current]. I found [N] v7 call sites across [M] files. Planning a two stage migration: v7 to v8, then v8 to v9.0.0."

## Phase 2: Plan

### Stage A — v7 to v8 removed and renamed APIs

Every item here is a breaking change removed in **PBL 8.0.0**. (Full depth: [pbl-v7-to-v8-migration](../pbl-v7-to-v8-migration/).)

| Area | PBL 7 (removed) | PBL 8 replacement |
|---|---|---|
| Product queries | `querySkuDetailsAsync()` | `queryProductDetailsAsync()` |
| Product details type | `SkuDetails` | `ProductDetails` |
| Query params | `SkuDetailsParams` | `QueryProductDetailsParams` |
| Response listener | `SkuDetailsResponseListener` | `ProductDetailsResponseListener` |
| Product type enum | `BillingClient.SkuType` | `BillingClient.ProductType` |
| Flow params list | `setSkuDetailsList()` | `setProductDetailsParamsList()` |
| Purchase history | `queryPurchaseHistoryAsync()`, `QueryPurchaseHistoryParams` | `queryPurchasesAsync(QueryPurchasesParams, ...)` (active/pending only) |
| Purchases query | `queryPurchasesAsync(String, listener)` | `queryPurchasesAsync(QueryPurchasesParams, listener)` |
| Pending purchases | `enablePendingPurchases()` (no args) | `enablePendingPurchases(PendingPurchasesParams)` |
| Alternative billing toggle | `enableAlternativeBilling()` | `enableUserChoiceBilling()` |
| Alternative billing listener | `AlternativeBillingListener` | `UserChoiceBillingListener` |
| Alternative choice details | `AlternativeChoiceDetails` | `UserChoiceDetails` |
| Proration enum | `ProrationMode` | `ReplacementMode` |
| Proration setter | `setReplaceProrationMode()` | `setSubscriptionReplacementMode()` |

### ProrationMode to ReplacementMode constant map

| `ProrationMode` (PBL 7) | `ReplacementMode` (PBL 8) |
|---|---|
| `IMMEDIATE_WITH_TIME_PRORATION` | `WITH_TIME_PRORATION` |
| `IMMEDIATE_AND_CHARGE_PRORATED_PRICE` | `CHARGE_PRORATED_PRICE` |
| `IMMEDIATE_AND_CHARGE_FULL_PRICE` | `CHARGE_FULL_PRICE` |
| `IMMEDIATE_WITHOUT_PRORATION` | `WITHOUT_PRORATION` |
| `DEFERRED` | `DEFERRED` |
| (none) | `KEEP_EXISTING` (PBL 8.1+) |

### Stage B — v8 to v9 delta

No removals. Four items, most conditional. (Full depth: [pbl-v8-to-v9-migration](../pbl-v8-to-v9-migration/).)

- Bump dependency to 9.0.0 and `targetSdk` to 35.
- Ensure androidx.core 1.9+.
- Blocked Play Store now returns `BILLING_UNAVAILABLE` instead of generic `ERROR`.
- `DeveloperProvidedBillingDetails.getLinkUri()` is now `@Nullable` (only if you use developer provided billing).
- Optional: in app messaging for opt in price increases.

Present both stages as one checklist and confirm before editing.

## Phase 3: Execute

Do Stage A end to end, get a clean compile, then do Stage B. Do not interleave: a clean v8 build is the checkpoint that proves the heavy work is done.

### Stage A: migrate to PBL 8

1. **Bump to the latest v8** (target 8.1+ so you also pick up `SubscriptionProductReplacementParams` and `includeSuspendedSubscriptions`).

   ```gradle
   implementation("com.android.billingclient:billing-ktx:8.1.0")
   ```

2. **Fix the `BillingClient` builder** — replace parameterless `enablePendingPurchases()` and add auto reconnection.

   ```kotlin
   BillingClient.newBuilder(context)
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

3. **Replace `querySkuDetailsAsync` with `queryProductDetailsAsync`** and switch display code off `SkuDetails` onto `ProductDetails` (base plans, offers, pricing phases). Read the `QueryProductDetailsResult.unfetchedProductList` in the same pass.
4. **Replace `queryPurchaseHistoryAsync`** with `queryPurchasesAsync` (active/pending only). Move historical lookups to the backend via the Play Developer API.
5. **Rename alternative billing to user choice billing** at every grep hit from Phase 1.
6. **Replace `ProrationMode` with `ReplacementMode`** using the constant map, and rename `setReplaceProrationMode` to `setSubscriptionReplacementMode`. On 8.1+, prefer `SubscriptionProductReplacementParams` attached to the product params.
7. **Bump `minSdk` to 23.** Review ProGuard/R8 keep rules that referenced removed classes (`SkuDetails`, `AlternativeBillingListener`).
8. **Compile clean and run tests.** This is the checkpoint. Resolve every reference to a removed v7 API before moving on.

### Stage B: migrate to PBL 9

Only after a clean v8 build, do the small v9 delta (full depth: [pbl-v8-to-v9-migration](../pbl-v8-to-v9-migration/)):

1. **Bump the dependency to 9.0.0.**

   ```gradle
   implementation("com.android.billingclient:billing-ktx:9.0.0")
   ```

2. **Ensure androidx.core 1.9+** and bump `compileSdk`/`targetSdk` to 35 (`minSdk` stays 23).
3. **Update blocked store error handling** — branch on `BILLING_UNAVAILABLE` with the "Play Store is blocked" debug message instead of generic `ERROR`.
4. **Handle nullable `getLinkUri()`** if you use developer provided billing (null + empty string guard before `Uri.parse`).
5. **Optionally adopt in app price increase messaging** via `showInAppMessages`.

## Phase 4: Verify

1. **Clean compile at v8, then at v9.** Two checkpoints. `./gradlew clean assembleDebug` each time.
2. **Unit tests** at both checkpoints (`./gradlew test`). Fix tests that stub old listener shapes or proration constants.
3. **Lifecycle tests on a real device** with the latest Play Store: new subscription, renewal, upgrade/downgrade with `ReplacementMode`, one time product purchase and consume, pending purchase completion.
4. **License test accounts** — repeat without real charges. Pay special attention to plan changes; the proration to replacement rename is the riskiest site.
5. **Auto reconnection smoke test** — sever the connection (airplane mode / force stop Play Store) and confirm reconnection without a manual `startConnection()`.
6. **v9 specific checks** — blocked store returns `BILLING_UNAVAILABLE`; nullable link URI does not crash; manifests merge at `targetSdk = 35`.
7. **Internal test track rollout** — monitor crash reports and billing success rates for at least one full billing cycle before promoting to production.

Report back a final summary: the old version, the two stage path taken, every rename applied in Stage A, the v9 adjustments in Stage B, and the verification evidence.

## References

- [Full chapter](https://www.revenuecat.com/guides/google-play-billing/appendix-migrating-from-pbl-7-to-pbl-8)
- [Google Play Billing Library v9 migration guide](https://developer.android.com/google/play/billing/migrate-gpblv9)
- [Play Billing Library release notes](https://developer.android.com/google/play/billing/release-notes)
- [RevenueCat Play Billing v9 deep dive](https://www.revenuecat.com/blog/engineering/play-billing-v9/)
- Upstream deadlines: PBL 7 last accepts new app and update submissions on August 31, 2026; PBL 8 on August 31, 2027. Migrate to v9 with margin to monitor at least one billing cycle.
