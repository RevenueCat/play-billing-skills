---
name: pbl-v8-to-v9-migration
description: "Use this skill when migrating an Android app from Play Billing Library 8.x to 9.x. Covers the small v9 delta (no API removals): the dependency bump, the targetSdk 35 and androidx.core requirements, the blocked Play Store error reclassification, the nullable getLinkUri change, the optional in app price increase messaging, and the verification flow."
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

State the key fact up front so the user calibrates effort correctly: **PBL 9.0.0 (released 2026-05-19) removed no APIs.** PBL 8.0.0 was the breaking release that deleted the `Sku*` family, `queryPurchaseHistoryAsync`, and the parameterless `enablePendingPurchases()`. PBL 9 builds on that surface with one target SDK bump, two compatibility adjustments, and one optional new feature. RevenueCat characterizes it as a single sprint of work for a v8 app.

If the project still references `SkuDetails`, `querySkuDetailsAsync`, `SkuType`, or the parameterless `enablePendingPurchases()`, the real baseline is pre-v8. Stop and route the user to [pbl-v7-to-v9-migration](../pbl-v7-to-v9-migration/), which does the v8 work first.

## Phase 1: Discovery

Gather the facts before changing anything.

1. **Locate the dependency.** Open `build.gradle`, `build.gradle.kts`, or `libs.versions.toml` and find `com.android.billingclient:billing` or `billing-ktx`. Confirm the version reads `8.x.x`. If it reads `7.x` or lower, switch to the [pbl-v7-to-v9-migration](../pbl-v7-to-v9-migration/) skill.
2. **Check androidx.core.** Find the `androidx.core:core` / `core-ktx` version. v9's error reclassification requires **androidx.core 1.9 or later**. Record the current value.
3. **Check compile and target SDK.** Read `compileSdk` and `targetSdk`. v9 targets API 35. Note both values.
4. **Scan for developer provided billing.** Grep for `DeveloperProvidedBillingDetails`, `getLinkUri`, `enableDeveloperBillingOption`, and `enableBillingProgram`. These are the External Payments APIs from PBL 8.3. If any hit, the nullable `getLinkUri()` change in Phase 3 applies. If none hit, you can skip that step.
5. **Scan error handling.** Grep for `BillingResponseCode.ERROR` and `BillingResponseCode.BILLING_UNAVAILABLE`. Note every place that branches on a generic `ERROR` for an unavailable store, because v9 reclassifies the blocked store case.
6. **Note in app messaging usage.** Grep for `showInAppMessages` and `InAppMessageParams`. If present, the optional price increase messaging step applies.

Report back: "You are on PBL [current]. androidx.core is [version], targetSdk is [value]. I found [N] developer provided billing sites and [M] generic ERROR branches to review. Planning a migration to PBL 9.0.0."

## Phase 2: Plan

Build the checklist. Only four items are mandatory; the rest are conditional.

| Step | Mandatory? | What it touches |
|---|---|---|
| Bump dependency to 9.0.0 | Yes | `build.gradle` / version catalog |
| Ensure androidx.core 1.9+ | Yes (to get the reclassified error) | `build.gradle` / version catalog |
| Bump compileSdk / targetSdk to 35 | Yes | `build.gradle`, manifest |
| Update blocked store error handling | If you branch on generic `ERROR` for store availability | `PurchasesUpdatedListener`, connection error paths |
| Handle nullable `getLinkUri()` | Only if you use developer provided billing (PBL 8.3 External Payments) | external payment launch code |
| Adopt in app price increase messaging | Optional | paywall / app resume code |

**There is no rename map and no removed API table for v9.** If you find yourself writing one, you are looking at the cumulative v8 migration guide, which restates v8.0.0 removals. Do not reintroduce them here.

Present the plan to the user as a checklist and confirm before editing files.

## Phase 3: Execute

### Step 1: Bump the dependency

```gradle
// Kotlin
implementation("com.android.billingclient:billing-ktx:9.0.0")
// Java/Groovy
implementation "com.android.billingclient:billing:9.0.0"
```

Sync Gradle. Because v9 removed nothing, expect a clean compile with no forced edits. The remaining steps are about correctly handling v9 behavior, not fixing compile errors.

### Step 2: Ensure androidx.core 1.9 or later

The error code reclassification in Step 4 ships behind androidx.core. Confirm the resolved version is 1.9+.

```gradle
implementation("androidx.core:core-ktx:1.13.1")
```

### Step 3: Bump compileSdk and targetSdk to 35

```gradle
android {
    compileSdk = 35
    defaultConfig {
        targetSdk = 35
        minSdk = 23 // unchanged from PBL 8.0
    }
}
```

`minSdk` stays at 23 (set in PBL 8.0). Apps on an older `compileSdk` may see manifest merger warnings until they align to 35.

### Step 4: Update blocked Play Store error handling

When the Play Store app is blocked by the system (OEM customized kids mode, parental controls, or managed enterprise devices), v9 reports **`BILLING_UNAVAILABLE`** instead of the generic `ERROR` it returned in v8. The `BillingResult` carries a "Play Store is blocked" debug message.

```kotlin
when (billingResult.responseCode) {
    BillingResponseCode.BILLING_UNAVAILABLE -> {
        if (billingResult.debugMessage.contains("Play Store is blocked")) {
            showBlockedStoreFallback() // kids tablet / enterprise device messaging
        } else {
            showBillingUnavailable()   // version too old, no Google account, etc.
        }
    }
    BillingResponseCode.ERROR -> showGenericRetry()
    // ...
}
```

Audit every site that previously treated a generic `ERROR` as "store unavailable" and move the blocked case onto `BILLING_UNAVAILABLE`. See [error-handling](../error-handling/) for the full classification.

### Step 5: Handle nullable `getLinkUri()` (developer provided billing only)

PBL 9 marks `DeveloperProvidedBillingDetails.getLinkUri()` as `@Nullable`. The external payment link may not be resolved at selection time, so guard against both `null` and empty string before parsing.

```kotlin
val linkUri = details.linkUri
if (!linkUri.isNullOrEmpty()) {
    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(linkUri)))
} else {
    showExternalPaymentUnavailableState()
}
```

Skip this step if Phase 1 found no developer provided billing usage.

### Step 6: Adopt in app messaging for opt in price increases (optional)

PBL 9 lets you surface an upcoming opt in price increase inside the app so the user can accept the new price without leaving for the Play Store. This reuses the existing `showInAppMessages` entry point. Google shows the message starting the first day the user can accept the increase, at most once every 7 days.

```kotlin
val params = InAppMessageParams.newBuilder()
    .addInAppMessageCategoryToShow(
        InAppMessageParams.InAppMessageCategoryId.TRANSACTIONAL
    ).build()

billingClient.showInAppMessages(activity, params) { result ->
    if (result.responseCode ==
        InAppMessageResult.InAppMessageResponseCode.SUBSCRIPTION_STATUS_UPDATED
    ) {
        refreshSubscriptionStatus() // user accepted the new price in the dialog
    }
}
```

The opt in price increase message is delivered through the same `TRANSACTIONAL` category already used for payment recovery; v9 adds price increases to what that category can surface. Confirm category behavior against the [in app messaging reference](https://developer.android.com/google/play/billing/integrate#in-app-messaging) for your library version before shipping. See [price-changes](../price-changes/) for the full opt in increase timeline and [payment-recovery](../payment-recovery/) for the existing `showInAppMessages` pattern.

## Phase 4: Verify

1. **Clean compile.** Run `./gradlew clean assembleDebug`. v9 should compile without forced changes; investigate any error as a sign the baseline was actually pre-v8.
2. **Unit tests.** Run `./gradlew test`.
3. **Blocked store path.** On a device or emulator where the Play Store is restricted (kids mode, managed profile), confirm the response code is now `BILLING_UNAVAILABLE` with the "Play Store is blocked" debug message, and that your fallback UI shows.
4. **Nullable link URI.** If you use developer provided billing, force a state where the link URI is unavailable and confirm no `Uri.parse("")` crash.
5. **targetSdk 35.** Confirm the build merges manifests cleanly at `targetSdk = 35` and the app behaves correctly under Android 15 behavior changes.
6. **Price increase messaging.** If adopted, configure an opt in increase in the Play Console and confirm the in app message renders and `SUBSCRIPTION_STATUS_UPDATED` refreshes entitlement state.
7. **Internal test track rollout.** Publish to the internal track, monitor crash reports and billing success rates for at least one billing cycle before promoting.

Report back a final summary: the old version, the new version (9.0.0), the conditional steps that applied, new behavior adopted, and the verification evidence.

## References

- [Full chapter](https://www.revenuecat.com/blog/engineering/play-billing-v9/)
- [Google Play Billing Library v9 migration guide](https://developer.android.com/google/play/billing/migrate-gpblv9)
- [Play Billing Library release notes](https://developer.android.com/google/play/billing/release-notes)
- Upstream deadline to track: PBL 8 last accepts new app and update submissions on August 31, 2027 (two year deprecation cycle, extension window through November 1, 2027). Already published v8 binaries keep transacting after that date, but you cannot ship new releases on v8.
