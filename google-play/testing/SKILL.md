---
name: testing
description: Use this skill when testing a Google Play Billing integration. Covers license test accounts, static test responses, Play Console sandbox purchases, and subscription lifecycle acceleration for renewals, grace period, and account hold.
license: Apache-2.0; see LICENSE
metadata:
  author: RevenueCat
  source: google-play-handbook chapter 16
  keywords:
  - android
  - play-billing
  - testing
  - sandbox
  - license-test
  - lifecycle-acceleration
---

# Testing Your Play Billing Integration

A billing build that runs on your laptop is not evidence that it works in production. Real users hit payment declines, pending cash payments, grace periods, and account holds. Use Google's license testers, Play Billing Lab, and the accelerated sandbox to exercise every state you claim to support before you release.

## Phase 1: Discovery

Before you test anything, confirm the environment is wired up. Skipping a step here leads to purchase dialogs that charge real money or flows that never show test cards.

Run through this checklist:

- **License testers list**: Play Console -> Settings -> License testing. The Gmail you test with must appear here. Testers are set at the developer account level, apply to every app you own, and propagate within minutes.
- **Test track upload**: Your APK or AAB must sit on internal, closed, or open testing. The license tester benefit only activates after you have uploaded the app at least once. Internal testing ships in minutes and is the right default for billing work.
- **Signed in account**: The license tester account must be on the test device. With several accounts, the purchase uses the account that downloaded the app, or the first account on the device if none did (for example a sideloaded debug build). Expand the purchase dialog to confirm which account is paying.
- **Play Billing Lab installed**: Install the Play Billing Lab companion app from the Play Store on the test device. You need it for country overrides, trial resets, state transitions, and the response simulator.
- **`enablePendingPurchases`**: every `BillingClient` that sets a purchases listener must call `enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())`, or `build()` throws. Add `enablePrepaidPlans()` only if you sell prepaid plans and handle pending prepaid purchases.

If any item is missing, fix that first. License tester tooling is invisible otherwise.

## Phase 2: Plan

Pick a strategy that matches what you changed. Running all 11 subscription test cases on every PR is wasteful. Running none is reckless.

| Change type | Minimum coverage |
|---|---|
| New purchase flow or product catalog | New purchase, acknowledgment, entitlement grant |
| Subscription lifecycle logic | Renewal, grace period, account hold, cancellation |
| Plan change or upgrade code | Each replacement mode you support, plus linkedPurchaseToken handling |
| RTDN or server integration | Renewal, grace, hold, revoke, refund notifications end to end |
| Error handling or retry paths | Response simulator sweep: `NETWORK_ERROR`, `ITEM_ALREADY_OWNED`, `USER_CANCELED`, `BILLING_UNAVAILABLE`; for a lost service connection, force stop the Play Store app while connected |
| Pre release candidate | Full 11 case suite plus one real payment on the cheapest SKU |

### Test product static responses

Inside the Play purchase dialog, license testers see five virtual instruments instead of real cards. Each one forces a deterministic outcome, so pick the one that matches the path you want to exercise.

| Test instrument | Result | Use when you are testing |
|---|---|---|
| Test card, always approves | Immediate success, `BillingResponseCode.OK` | Happy path, acknowledgment, entitlement grant |
| Test card, always declines | Immediate failure, `BillingResponseCode.ERROR` | Decline UI, error messaging, absence of entitlement grant |
| Slow test card, approves after a few minutes | Pending state, then success after minutes | Pending purchase handling, UI state, `PurchasesUpdatedListener` firing twice |
| Slow test card, declines after a few minutes | Pending state, then final failure | Pending decline path, cleanup of pending UI |
| Test card, approves then charges back | Success, then a simulated chargeback initiated by the user | Chargeback and refund review handling, `PendingRefundReviewNotification` RTDN |

Before you pick an instrument, decide what signal proves the test passed: a specific response code, a purchase state transition, an RTDN on your server, or an entitlement change in the app. Write it down first.

### Pick a lifecycle scenario

If you are exercising the subscription state machine, choose one of these as your first target:

- **Renewal succeeds**: cheapest scenario, verifies RTDN plumbing.
- **Grace period enter and recover**: verifies you keep access up during grace and re grant after recovery.
- **Account hold enter and recover**: verifies you revoke access during hold and restore after payment fix.
- **Pause and resume**: only if your product allows pausing.
- **Upgrade with replacement mode**: verifies `linkedPurchaseToken` handling on the server (the app only sees the new purchase token).

## Phase 3: Execute

### Step 1: Run a sandbox purchase

Open your app on the test device signed in with the license tester account.

1. Trigger your normal product list query. Confirm prices render and the product appears.
2. Launch the billing flow. Expect the Play purchase sheet to show the five test instruments rather than real cards.
3. Pick "Test card, always approves".
4. Confirm `PurchasesUpdatedListener` fires with `BillingResponseCode.OK` and a `Purchase` in the `PURCHASED` state.
5. Acknowledge the purchase from your server or client path.
6. Call `queryPurchasesAsync` and confirm the purchase is returned as active.
7. Confirm your app grants the matching entitlement.

To prove your acknowledgment path works, repeat the flow but skip step 5 on purpose:

1. Make the purchase.
2. Do not acknowledge.
3. Wait 3 minutes.
4. Re query purchases and confirm Google has auto refunded and the entitlement is gone.

If the entitlement is still present after 3 minutes, your app is caching state without rechecking. Fix that before shipping.

### Step 2: Accelerate the subscription lifecycle

Test subscriptions run on a compressed schedule automatically. You do not configure this.

| Production renewal period | Test renewal period |
|---|---|
| Weekly | 5 minutes |
| Monthly | 5 minutes |
| Quarterly | 10 minutes |
| Semi annual | 15 minutes |
| Yearly | 30 minutes |

Intermediate states compress too: free trial runs 3 minutes, grace period runs 5 minutes, account hold runs 10 minutes. Test subscriptions cancel after 6 renewals regardless of period, so plan accordingly.

To watch a full lifecycle in under 20 minutes:

1. Start a new monthly subscription using the always approves test card.
2. Wait 5 minutes for the first renewal. Confirm your server receives an RTDN with `SUBSCRIPTION_RENEWED` and the entitlement remains active.
3. Open Play Billing Lab and trigger a payment failure at the next renewal.
4. Verify the subscription enters grace period and your app still grants access.
5. Wait 5 minutes. Grace expires, the subscription moves to account hold, your app revokes access.
6. Wait 10 minutes. Account hold expires and the subscription cancels.
7. Confirm RTDNs for `SUBSCRIPTION_IN_GRACE_PERIOD`, `SUBSCRIPTION_ON_HOLD`, and `SUBSCRIPTION_CANCELED` each landed.

Use Play Billing Lab to force specific transitions instead of waiting on timers when you only need to verify one state. It also lets you reset trial eligibility so you can rerun trial sign up on the same account.

### Step 3: Exercise error paths with the response simulator

Play Billing Lab ships a response simulator that overrides the `BillingResult` of `launchBillingFlow`, `acknowledgePurchase`, `consumeAsync`, and `queryProductDetailsAsync` with a chosen positive response code. It cannot return negative codes such as `SERVICE_DISCONNECTED`, and it does not drop the service connection. Configure a rule, run the flow, confirm your app recovers.

Opt the test build in (PBL 7.1.1+), in a debug or test manifest only:

```xml
<meta-data android:name="com.google.android.play.largest_release_audience.NONPRODUCTION" android:value="" />
<meta-data android:name="com.google.android.play.billingclient.enableBillingOverridesTesting" android:value="true" />
```

Open Play Billing Lab before your app, and confirm the Play Billing Lab status bar icon shows the connection.

Minimum response codes to cover:

- Lost service connection (not simulated: force stop the Play Store app while connected): your app reconnects on the next call and retries.
- `NETWORK_ERROR` on `acknowledgePurchase`: your app retries, because unacknowledged purchases refund in 3 days in production.
- `ITEM_ALREADY_OWNED` on `launchBillingFlow`: your app refreshes purchases and messages the user correctly.
- `USER_CANCELED`: your app returns to the previous screen without an error banner.
- `BILLING_UNAVAILABLE` on connect: your app hides purchase options gracefully.

### Step 4: Enable pending purchases

Pending purchases are mandatory for one time products. Configure your client once and then test with the slow approve card.

```kotlin
val billingClient = BillingClient.newBuilder(context)
    .setListener(purchasesUpdatedListener)
    .enablePendingPurchases(
        PendingPurchasesParams.newBuilder()
            .enableOneTimeProducts()
            // .enablePrepaidPlans() // only if you sell prepaid plans and handle pending prepaid purchases
            .build()
    )
    .build()
```

Guard entitlement grants by purchase state:

```kotlin
when (purchase.purchaseState) {
    Purchase.PurchaseState.PURCHASED -> grantAndAcknowledge(purchase)
    Purchase.PurchaseState.PENDING -> showPendingUi(purchase)
    else -> Unit
}
```

Verify the pending to purchased transition delivers a second `PurchasesUpdatedListener` callback (or appears in `queryPurchasesAsync()` on resume), that a declined slow card never grants access after an app restart, and that your server processes `ONE_TIME_PRODUCT_PURCHASED`/`SUBSCRIPTION_PURCHASED` or `ONE_TIME_PRODUCT_CANCELED`/`SUBSCRIPTION_PENDING_PURCHASE_CANCELED`.

### Step 5: One real payment before production

License tester cards do not exercise 3D Secure prompts, card verification, refund processing, or financial reporting. Before your first production push:

1. Make one real purchase on your cheapest product using an account on your internal test track.
2. Request a refund through Google Play. Verify the refund RTDN arrives and your app revokes access.
3. Confirm the purchase and refund both appear in Play Console financial reports.

## Common mistakes

- Caching entitlements locally without revalidating against `queryPurchasesAsync`. The 3 minute auto refund window exposes this.
- Granting access during `PENDING` state. The slow decline card exposes this.
- Treating a restored subscription as a new purchase after a user cancels and resubscribes inside the same period.
- Using `CHARGE_PRORATED_PRICE` on a downgrade. It will fail at runtime.
- Revoking access the moment the user cancels, instead of at period end.
- Revoking access during grace period, which is meant to preserve access while Google retries payment.

## References

- [Full chapter](https://www.revenuecat.com/guides/google-play-billing/testing-your-integration)
