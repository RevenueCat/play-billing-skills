---
name: payment-recovery
description: Use this skill when handling failed renewals on Android with RevenueCat. Covers how Grace Period and Account Hold are reflected in CustomerInfo automatically, when to prompt the user, and how to trigger Google's in app messaging via showInAppMessages.
license: Apache-2.0; see LICENSE
metadata:
  author: RevenueCat
  source: revenuecat-handbook chapter 12
  keywords:
  - android
  - revenuecat
  - payment-recovery
  - grace-period
  - account-hold
  - in-app-messaging
---

# Payment Recovery

Failed renewals on Google Play move a subscription through two states: grace period (user keeps access while Google retries the card) and account hold (access revoked until the user fixes the payment method). With RevenueCat, both states land in `CustomerInfo` automatically, and Google's in app message shows by default.

## Phase 1: Understand

A failed renewal leads to one of these states:

| State | Access | How RevenueCat surfaces it | User sees |
| --- | --- | --- | --- |
| Grace period | Retained | `entitlement.isActive == true` and `billingIssueDetectedAt != null` | Google in app snackbar by default |
| Account hold | Revoked | `entitlement.isActive == false` and `billingIssueDetectedAt != null` | Google in app snackbar by default |
| Expired without recovery | Revoked | Same as account hold, because `billingIssueDetectedAt` stays set after the subscription ends | Your account hold screen and its paywall path |
| Recovered | Retained | `billingIssueDetectedAt == null` | Nothing |

Two signals matter in the SDK:

- `EntitlementInfo.billingIssueDetectedAt` is non null from the moment Google reports a billing problem until the user resolves it.
- `EntitlementInfo.isActive` tells you whether they still have access.

On the backend, a `BILLING_ISSUE` webhook fires once per transition. You do not decode RTDNs.

## Phase 2: Plan

Before you write app code, decide what you actually need. Most apps need none.

Ask:

1. Do you want the default Google in app message? If yes, do nothing. The SDK calls `showInAppMessagesIfNeeded` each time an Activity starts.
2. Do you want your own banner or dialog? If yes, read `billingIssueDetectedAt` from `CustomerInfo` and branch on `isActive`.
3. Do you want to gate the message to specific screens? If yes, disable the automatic call and invoke `showInAppMessagesIfNeeded(activity)` yourself.
4. Do you need a server side flag (for example, to send a recovery email)? If yes, handle the `BILLING_ISSUE` webhook. No app code required.

If you only want the default behavior, stop here.

## Phase 3: Execute

### Default (recommended)

Leave automatic in app messages on. This is the default:

```kotlin
PurchasesConfiguration.Builder(context, apiKey)
    .showInAppMessagesAutomatically(true)
    .build()
```

### Manual trigger

Disable the automatic call and show the message from your chosen activity:

```kotlin
PurchasesConfiguration.Builder(context, apiKey)
    .showInAppMessagesAutomatically(false)
    .build()

Purchases.sharedInstance.showInAppMessagesIfNeeded(activity)
```

### Your own UI during grace period

Read the entitlement and branch on both flags:

```kotlin
val entitlement = customerInfo.entitlements["pro_access"]
when {
    entitlement == null ->
        showSubscribeScreen()
    entitlement.isActive && entitlement.billingIssueDetectedAt != null ->
        showGracePeriodWarning()
    entitlement.isActive ->
        showPremiumContent()
    entitlement.billingIssueDetectedAt != null ->
        showAccountHoldScreen()
    else ->
        showSubscribeScreen()
}
```

Check `billingIssueDetectedAt` before falling back to the subscribe screen. An inactive entitlement with a billing issue is usually account hold, where fixing the payment method restores the existing subscription. Buying again also restores access, and RevenueCat clears `billingIssueDetectedAt` only when the issue is resolved, so a subscription that expired without recovery can still carry it. Lead the account hold screen with the fix payment link and keep a path to the paywall.

### Send the user to fix payment

`CustomerInfo.managementURL` points to the Google Play subscription page:

```kotlin
customerInfo.managementURL?.let { url ->
    startActivity(Intent(Intent.ACTION_VIEW, url))
}
```

## Phase 4: Verify

Test each transition:

- Use a Google Play test card that declines renewals to push a subscription into grace period.
- Confirm `entitlement.billingIssueDetectedAt` becomes non null and `isActive` stays `true`.
- Wait for account hold and confirm `isActive` flips to `false` while `billingIssueDetectedAt` remains non null.
- Update the payment method and confirm `billingIssueDetectedAt` returns to `null`.
- On backend, confirm a `BILLING_ISSUE` webhook fires on the first transition.

## References

- [Full chapter](https://www.revenuecat.com/guides/revenuecat-android-sdk/payment-recovery)
