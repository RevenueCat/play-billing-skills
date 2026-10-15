---
name: pbl-v8-to-v9-migration
description: "Use this skill when migrating an Android app from Play Billing Library 8.x to 9.x (latest 9.1.0). Covers the v9 delta: the dependency bump, the removed Sku* and QueryPurchaseHistoryParams types, the compileSdk 35 and Kotlin 2.2 (billing-ktx) floors, the blocked Play Store error reclassification, the nullable getLinkUri change, the optional in app price increase messaging, and the verification flow."
license: Apache-2.0; see LICENSE
metadata:
  author: RevenueCat
  source: Google Play Billing Library v9 migration guide and release notes; RevenueCat Play Billing v9 deep dive
  keywords:
  - android
  - play-billing
  - pbl9
  - migration
  - breaking-changes
---

## Phase 0: Intent

Announce to the user: "I will migrate this project from PBL 8 to PBL 9."

State the key fact up front so the user calibrates effort correctly: **the v9 delta is small, but it is not zero.** PBL 8.0.0 removed the methods of the old surface (`querySkuDetailsAsync`, `queryPurchaseHistoryAsync`, the `String` overload of `queryPurchasesAsync`, the parameterless `enablePendingPurchases()`). PBL 9.0.0 (released 2026-05-19) then deleted the deprecated types those methods left behind: `BillingClient.SkuType`, `SkuDetails`, `SkuDetailsParams`, `SkuDetailsResponseListener`, `QueryPurchaseHistoryParams`, and `BillingFlowParams.Builder.setSkuDetails()`. A v8 app that still references any of them stops compiling. On top of that, v9 raises the build floor (compileSdk 35, and Kotlin 2.2 if you use `billing-ktx`), changes two behaviors, and adds one optional feature. The latest release is **9.1.0** (2026-06-18), which adds the Billing Choice APIs on top of 9.0.0; target it.

If the project calls `querySkuDetailsAsync`, `queryPurchaseHistoryAsync`, or the parameterless `enablePendingPurchases()`, it does not compile against v8 at all, so the real baseline is pre-v8. Stop and route the user to [pbl-v7-to-v9-migration](../pbl-v7-to-v9-migration/), which does the v8 work first. Leftover references to the `SkuType` constants or the `SkuDetails` types alone are normal in a v8 codebase: they are the v9 removals handled in Step 2.

## Phase 1: Discovery

Gather the facts before changing anything.

1. **Locate the dependency.** Open `build.gradle`, `build.gradle.kts`, or `libs.versions.toml` and find `com.android.billingclient:billing` or `billing-ktx`. Confirm the version reads `8.x.x`. If it reads `7.x` or lower, switch to the [pbl-v7-to-v9-migration](../pbl-v7-to-v9-migration/) skill. Record which artifact is used; `billing-ktx` adds a Kotlin requirement.
2. **Scan for the types v9 removed.** Grep for `SkuType`, `SkuDetails`, `SkuDetailsParams`, `SkuDetailsResponseListener`, `QueryPurchaseHistoryParams`, and `setSkuDetails(`. Every hit is a compile error on v9.
3. **Check the build floor.** Read `compileSdk`, `minSdk`, `targetSdk`, and the Kotlin Gradle plugin version. v9 needs `compileSdk` 35 or higher (it depends on `androidx.core:core:1.15.0`, which declares a minimum compileSdk of 35, so the build fails below it) and `minSdk` 23 (unchanged since PBL 8.1). With `billing-ktx`, the Kotlin Gradle plugin must be 2.2 or newer. `targetSdk` is not set by PBL; record it for the note in Step 3.
4. **Check for a pinned androidx.core.** v9's blocked store reclassification needs androidx.core 1.9 or later. PBL 9 already pulls 1.15.0 transitively, so this only breaks if the build forces a lower version. Grep the build files for `androidx.core` together with `force`, `strictly`, or `resolutionStrategy`.
5. **Scan for developer provided billing.** Grep for `DeveloperProvidedBillingDetails`, `getLinkUri`, `enableDeveloperBillingOption`, and `enableBillingProgram`. These are the External Payments APIs from PBL 8.3. If any hit, the nullable `getLinkUri()` change in Step 5 applies. If none hit, you can skip that step.
6. **Scan error handling.** Grep for `BillingResponseCode.ERROR` and `BillingResponseCode.BILLING_UNAVAILABLE`. Note every place that branches on a generic `ERROR` for an unavailable store, because v9 reclassifies the blocked store case.
7. **Note in app messaging usage.** Grep for `showInAppMessages` and `InAppMessageParams`. If present, the optional price increase messaging step applies.

Report back: "You are on PBL [current]. compileSdk is [value], Kotlin is [version]. I found [K] references to types removed in v9, [N] developer provided billing sites, and [M] generic ERROR branches to review. Planning a migration to PBL 9.1.0."

## Phase 2: Plan

Build the checklist. The dependency bump and the build floor apply to every app; the rest are conditional.

| Step | Mandatory? | What it touches |
|---|---|---|
| Bump dependency to 9.1.0 | Yes | `build.gradle` / version catalog |
| Replace the types removed in 9.0.0 | If Phase 1 found any | product type constants, legacy `SkuDetails` code |
| Raise `compileSdk` to 35+ (and Kotlin to 2.2+ with `billing-ktx`) | Yes | `build.gradle`, Kotlin plugin version |
| Unpin androidx.core | Only if a constraint forces it below 1.9 | `build.gradle` / version catalog |
| Update blocked store error handling | If you branch on generic `ERROR` for store availability | `PurchasesUpdatedListener`, connection error paths |
| Handle nullable `getLinkUri()` | Only if you use developer provided billing (PBL 8.3 External Payments) | external payment launch code |
| Adopt in app price increase messaging | Optional | paywall / app resume code |

The removal list for v9 is short:

| Removed in 9.0.0 | Use instead |
|---|---|
| `BillingClient.SkuType` (`INAPP`, `SUBS`) | `BillingClient.ProductType` (`INAPP`, `SUBS`, same string values) |
| `SkuDetails` | `ProductDetails` |
| `SkuDetailsParams`, `SkuDetailsResponseListener` | `QueryProductDetailsParams` and `ProductDetailsResponseListener` with `queryProductDetailsAsync()` |
| `BillingFlowParams.Builder.setSkuDetails()` | `setProductDetailsParamsList()` |
| `QueryPurchaseHistoryParams` | `queryPurchasesAsync(QueryPurchasesParams, ...)` for active and pending purchases; track consumed purchases on your backend; use the Voided Purchases API for refunds and revocations |

Do not copy the v8.0.0 method removals (`querySkuDetailsAsync`, `queryPurchaseHistoryAsync`, and the rest) into this plan. They are already gone in any code that compiles on v8.

Present the plan to the user as a checklist and confirm before editing files.

## Phase 3: Execute

### Step 1: Bump the dependency

```gradle
// Kotlin
implementation("com.android.billingclient:billing-ktx:9.1.0")
// Java/Groovy
implementation "com.android.billingclient:billing:9.1.0"
```

Sync Gradle. Expect compile errors only at the sites Phase 1 found: the removed types (Step 2) and Kotlin call sites that assumed a non null `getLinkUri()` (Step 5). Everything else in the v8 surface carries over unchanged.

### Step 2: Replace the types removed in 9.0.0

Most v8 codebases only have leftover `SkuType` constants. They hold the same strings as `ProductType`, so the swap is mechanical:

```kotlin
// Compiles on 8.x, fails on 9.x
.setProductType(BillingClient.SkuType.SUBS)
// Use
.setProductType(BillingClient.ProductType.SUBS)
```

Replace any remaining `SkuDetails` based code paths with `ProductDetails`. No v8 query returns a `SkuDetails`, so most of this code is dead, but code that rebuilds one from cached JSON (`SkuDetails(json)` passed to `setSkuDetails()`) still runs on v8 and must move to `ProductDetails` before you delete it. If old code relied on purchase history to decide free trial eligibility, rely on `queryProductDetailsAsync()` instead: Play only returns the offers the user is eligible for.

### Step 3: Raise compileSdk (and Kotlin for billing-ktx)

```gradle
android {
    compileSdk = 35 // minimum for PBL 9; keep a higher value if you already have one
    defaultConfig {
        minSdk = 23 // PBL floor since 8.1, unchanged in 9
        // targetSdk: not driven by PBL, see the note below
    }
}
```

Below compileSdk 35 the build fails in the `checkAarMetadata` task, because `androidx.core:core:1.15.0` (a PBL 9 dependency) requires it. With `billing-ktx`, set the Kotlin Gradle plugin to 2.2 or newer: `billing-ktx` 9.x is compiled with Kotlin 2.3 metadata, and Kotlin 2.1 fails with "module was compiled with an incompatible version of Kotlin". The plain `billing` artifact has no Kotlin requirement.

Do not lower or raise `targetSdk` for PBL 9. The library's own targetSdkVersion 35 is not a requirement on your app. Your `targetSdk` follows Play's target API level policy: since August 31, 2026, new apps and app updates must target API 36 (Wear OS and Android Automotive OS 35, Android TV and Android XR 34). If the project targets lower, tell the user it blocks the release independently of this migration, and handle it as its own change because it brings Android behavior changes.

If Phase 1 found a constraint that forces androidx.core below 1.9, remove it. Otherwise there is nothing to add: PBL 9 already brings 1.15.0.

### Step 4: Update blocked Play Store error handling

When the Play Store app is blocked by the system (for example in an OEM customized kids mode), v9 reports **`BILLING_UNAVAILABLE`** instead of the generic `ERROR` it returned in v8, and the `BillingResult` carries a "Play Store is blocked" debug message. Treat it like any other `BILLING_UNAVAILABLE`: billing is not available on this device or account right now, so show an unavailable state instead of retrying.

```kotlin
when (billingResult.responseCode) {
    BillingResponseCode.BILLING_UNAVAILABLE -> {
        // Since PBL 9 this also covers a Play Store blocked by the system (for example a kids mode)
        log("Billing unavailable: ${billingResult.debugMessage}")
        showBillingUnavailable() // no automatic retry
    }
    BillingResponseCode.ERROR -> showGenericRetry()
    // ...
}
```

Log the debug message, but do not branch on its text: it is diagnostic output, not an API contract. Audit every site that previously treated a generic `ERROR` as "store unavailable" and move that handling onto `BILLING_UNAVAILABLE`. See [error-handling](../error-handling/) for the full classification.

### Step 5: Handle nullable `getLinkUri()` (developer provided billing only)

PBL 9 marks `DeveloperProvidedBillingDetails.getLinkUri()` as `@Nullable` (it was `@NonNull` in 8.3), so Kotlin now sees `String?`. The external payment link may not be available at selection time, so guard against both `null` and empty string before parsing.

```kotlin
val linkUri = details.linkUri
if (!linkUri.isNullOrEmpty()) {
    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(linkUri)))
} else {
    showExternalPaymentUnavailableState()
}
```

Skip this step if Phase 1 found no developer provided billing usage.

### Step 6: Adopt in app messaging for opt in price increases (optional)

PBL 9 lets you surface an upcoming opt in price increase inside the app so the user can accept the new price without leaving for the Play Store. This reuses the existing `showInAppMessages` entry point with the `TRANSACTIONAL` category, the same one that shows payment issue messages. Google shows the price increase message starting the first day the user can accept the increase, at most once every 7 days. Call it whenever the user opens the app.

```kotlin
val params = InAppMessageParams.newBuilder()
    .addInAppMessageCategoryToShow(
        InAppMessageParams.InAppMessageCategoryId.TRANSACTIONAL
    ).build()

billingClient.showInAppMessages(activity, params) { result ->
    if (result.responseCode ==
        InAppMessageResult.InAppMessageResponseCode.SUBSCRIPTION_STATUS_UPDATED
    ) {
        // The user accepted the price increase or fixed their payment.
        // Refresh state from your backend with result.purchaseToken.
        refreshSubscriptionStatus(result.purchaseToken)
    }
}
```

See the [in app messaging guide](https://developer.android.com/google/play/billing/subscriptions#in-app-messaging), [price-changes](../price-changes/) for the full opt in increase timeline, and [payment-recovery](../payment-recovery/) for the existing `showInAppMessages` pattern.

PBL 9.1 also adds the Billing Choice APIs (`getBillingChoiceInfoAsync`, `showBillingProgramInformationDialog`). They only matter if the app takes part in a Google alternative billing program; see [alternative-billing](../alternative-billing/). They are not part of the migration.

## Phase 4: Verify

1. **Clean compile.** Run `./gradlew clean assembleDebug`. The only expected compile errors are the removed types from Step 2 and Kotlin nullability at `getLinkUri()` call sites. A `checkDebugAarMetadata` failure means compileSdk is still below 35; "incompatible version of Kotlin" means the Kotlin plugin is older than 2.2. Any other compile error is a sign the baseline was actually pre-v8.
2. **Unit tests.** Run `./gradlew test`.
3. **Resolved versions.** Confirm the release runtime classpath resolves `com.android.billingclient:billing:9.1.0` and `androidx.core:core` 1.15.0 or later, and that the merged manifest declares `com.google.android.play.billingclient.version` as 9.1.0. Play Console reads that entry to decide which library version a release ships.
4. **Blocked store path.** On a device or emulator where the Play Store is restricted (for example a kids mode), confirm the response code is now `BILLING_UNAVAILABLE`, the debug message mentions the blocked Play Store, and your unavailable state shows.
5. **Nullable link URI.** If you use developer provided billing, force a state where the link URI is unavailable and confirm no `Uri.parse("")` crash.
6. **Price increase messaging.** If adopted, configure an opt in increase in the Play Console and confirm the in app message renders and `SUBSCRIPTION_STATUS_UPDATED` refreshes entitlement state.
7. **Internal test track rollout.** Publish to the internal track, monitor crash reports and billing success rates for at least one billing cycle before promoting.

Report back a final summary: the old version, the new version (9.1.0), the conditional steps that applied, new behavior adopted, and the verification evidence.

## References

- [Full chapter](https://www.revenuecat.com/blog/engineering/play-billing-v9/)
- [Google Play Billing Library v9 migration guide](https://developer.android.com/google/play/billing/migrate-gpblv9)
- [Play Billing Library release notes](https://developer.android.com/google/play/billing/release-notes)
- Upstream deadline to track: PBL 8 last accepts new app and update submissions on August 31, 2027 (two year deprecation cycle, extension window through November 1, 2027). Already published v8 binaries keep transacting after that date, but you cannot ship new releases on v8. PBL 9 is accepted until August 31, 2028.
