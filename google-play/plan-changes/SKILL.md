---
name: plan-changes
description: Use this skill when implementing Google Play subscription upgrades, downgrades, or plan switches with setSubscriptionUpdateParams. Covers the six replacement modes (WITH_TIME_PRORATION, CHARGE_PRORATED_PRICE, WITHOUT_PRORATION, DEFERRED, CHARGE_FULL_PRICE, the deprecated UNKNOWN) and when each applies.
license: Apache-2.0; see LICENSE
metadata:
  author: RevenueCat
  source: google-play-handbook chapter 7
  keywords:
  - android
  - play-billing
  - subscriptions
  - upgrade
  - downgrade
  - proration
  - replacement-mode
---

# Plan Changes: Upgrades, Downgrades, and Plan Switches

Plan changes on Google Play Billing Library (PBL) 9.x always mint a new purchase token. You pick a replacement mode that controls two things: when the user gets access to the new plan, and how Google handles the money between the old and new agreement. This skill walks you through selecting the correct mode and wiring it into `BillingFlowParams`.

## Phase 1: Scope the Change

Before touching code, answer four questions about the requested switch:

1. Direction: is this an upgrade (new plan costs more), a downgrade (new plan costs less), or a lateral switch (same price, different cadence)?
2. Billing period: are you moving between plans with the same billing period (monthly to monthly) or across periods (monthly to annual, recurring to prepaid)?
3. Promotional state: is the user currently inside a free trial or introductory price window that should survive the switch?
4. Additivity: is the new SKU replacing the old subscription, or should it sit alongside the old one as an add on?

Write those four answers down. Every decision in Phase 2 follows directly from them.

You also need two inputs from the client at runtime:

- `oldPurchaseToken`: the purchase token for the subscription the user is leaving.
- `ProductDetails` and offer token for the new plan, fetched through `queryProductDetailsAsync`.

If either is missing, stop and fetch it first. Launching the billing flow without a valid `oldPurchaseToken` produces a new standalone subscription rather than a plan change.

## Phase 2: Plan the Replacement Mode

PBL 9.x exposes replacement modes through the `ReplacementMode` interface. `UNKNOWN` is deprecated; do not select it. The five modes you actually pick from are listed below, along with `KEEP_EXISTING` which arrived in PBL 8.1 for add on bundles.

### Mode Decision Table

Use this table to map your Phase 1 answers to a mode.

| Scenario | Recommended Mode | Immediate Charge? | Access Switch |
|---|---|---|---|
| Standard upgrade, fair to user | `WITH_TIME_PRORATION` | No | Immediate, renewal shifts forward |
| Upgrade, keep renewal date stable | `CHARGE_PRORATED_PRICE` | Yes, prorated difference | Immediate, renewal unchanged |
| Switch to or from a prepaid plan | `CHARGE_FULL_PRICE` | Yes, full new price | Immediate |
| Upgrade during a free trial or intro price | `WITHOUT_PRORATION` | No, settles at next renewal | Immediate, trial preserved |
| Downgrade | `DEFERRED` | No | At next renewal |
| Subscription add on, both plans active | `KEEP_EXISTING` | Yes, new plan charged | Immediate, existing plan untouched |

Two rules keep you out of trouble:

- `CHARGE_PRORATED_PRICE` only works for upgrades. Using it on a downgrade makes the billing flow fail because Google does not refund through proration.
- `CHARGE_FULL_PRICE` is required for any switch that involves a prepaid plan, since prepaid plans have no recurring cycle to prorate.

### Trade offs to Communicate in Your UI

Each mode has a user facing surprise you need to preempt:

- `WITH_TIME_PRORATION` shortens the next renewal interval on upgrades. Show the new renewal date.
- `CHARGE_PRORATED_PRICE` posts a small charge now. Show the amount before launching the flow.
- `CHARGE_FULL_PRICE` posts the full new price now. Do not hide this behind a generic confirmation.
- `WITHOUT_PRORATION` gives paid access until next renewal. Outside trials this is revenue you chose to give away.
- `DEFERRED` delays the switch. Tell the user "You will switch to Basic on <date>" using the current line item's `expiryTime`.

### The Play Console Default

You can configure a default replacement mode per subscription in Play Console under Monetize > Subscriptions. That default only applies when the client omits the mode from `BillingFlowParams`. Treat it as a safety net, not a substitute for setting the mode explicitly in code.

## Phase 3: Wire Up SubscriptionProductReplacementParams

`SubscriptionUpdateParams` is the deprecated path. Starting with PBL 8.1, build `SubscriptionProductReplacementParams` and attach it to the product parameters instead.

Build the replacement params with the mode you picked in Phase 2. The example below implements a standard upgrade that keeps the billing date stable.

```kotlin
val replacement = BillingFlowParams
    .SubscriptionProductReplacementParams
    .newBuilder()
    .setOldPurchaseToken(currentPurchaseToken)
    .setReplacementMode(
        ReplacementMode.CHARGE_PRORATED_PRICE
    )
    .build()
```

Attach it to `ProductDetailsParams` for the new plan:

```kotlin
val productParams = BillingFlowParams
    .ProductDetailsParams.newBuilder()
    .setProductDetails(premiumDetails)
    .setOfferToken(premiumOfferToken)
    .setSubscriptionReplacementParams(replacement)
    .build()
```

Launch the flow:

```kotlin
val flowParams = BillingFlowParams.newBuilder()
    .setProductDetailsParams(listOf(productParams))
    .build()

billingClient.launchBillingFlow(activity, flowParams)
```

The structural change from the deprecated API is that replacement data rides with the product, not with the flow. That shape matches what you are saying: "I want this product, and it should replace this existing subscription."

### Handling the Result

`PurchasesUpdatedListener` receives a new `Purchase` with a new purchase token. Send that token to your backend. Your server then calls `purchases.subscriptionsv2.get` and inspects `linkedPurchaseToken`:

```kotlin
fun handleNewPurchaseToken(newToken: String) {
    val subscription = playApi
        .getSubscriptionV2(packageName, newToken)
    val linked = subscription.linkedPurchaseToken
    if (linked != null) {
        database.markReplaced(linked)
    }
    database.insertSubscription(
        purchaseToken = newToken,
        productId = subscription.productId,
        status = "ACTIVE"
    )
}
```

Walk the chain if you may have missed prior notifications: the linked token might itself have been replaced by an even older token you still show as active.

### Deferred Mode Specifics

With `DEFERRED`, the new token arrives immediately but carries two line items: the current plan (active, with an `expiryTime`) and the new plan (pending via `deferredItemReplacement`). Grant entitlement based on the active line item and schedule the switch for the expiry time:

```kotlin
for (item in subscription.lineItems) {
    if (item.deferredItemReplacement != null) {
        upcomingProductId = item.productId
    } else {
        currentProductId = item.productId
        switchAt = item.expiryTime
    }
}
```

When the renewal fires, Google sends an RTDN and you promote the pending plan to active.

## Verification Checklist

Before shipping a plan change flow, confirm all of the following:

- You set `oldPurchaseToken` on `SubscriptionProductReplacementParams` using the token from the active subscription, not a stale cached value.
- The replacement mode matches the direction and promotional state from Phase 1.
- You do not pass `CHARGE_PRORATED_PRICE` for downgrades.
- Any switch involving a prepaid plan uses `CHARGE_FULL_PRICE`.
- Your backend reads `linkedPurchaseToken` and marks the old record replaced before activating the new one.
- For `DEFERRED`, your UI surfaces the scheduled switch date from the current line item's `expiryTime`.
- You acknowledge the new purchase on your backend after verification.

## References

- [Full chapter](https://www.revenuecat.com/guides/google-play-billing/subscription-upgrades-downgrades-and-plan-changes)
