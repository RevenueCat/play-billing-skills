---
name: plan-changes
description: Use this skill when implementing Google Play subscription upgrades, downgrades, or plan switches with SubscriptionProductReplacementParams (PBL 8.1+) plus SubscriptionUpdateParams.setOldPurchaseToken. Covers the replacement modes (WITH_TIME_PRORATION, CHARGE_PRORATED_PRICE, WITHOUT_PRORATION, CHARGE_FULL_PRICE, DEFERRED, KEEP_EXISTING) and when each applies.
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

You also need three inputs from the client at runtime:

- `oldPurchaseToken`: the purchase token for the subscription the user is leaving.
- `oldProductId`: the product ID of the subscription being replaced (from the active `Purchase.products`), for `SubscriptionProductReplacementParams.setOldProductId`.
- `ProductDetails` and offer token for the new plan, fetched through `queryProductDetailsAsync`.

If any is missing, stop and fetch it first. Launching the billing flow without a valid `oldPurchaseToken` produces a new standalone subscription when the target is a different subscription (within the same subscription, Play applies the base plan's default replacement mode).

Also confirm the current purchase is acknowledged (`Purchase.isAcknowledged`); Play blocks plan changes while it is pending acknowledgement. If the original purchase used `setObfuscatedAccountId`, pass the same value on the plan change `BillingFlowParams`.

## Phase 2: Plan the Replacement Mode

PBL 8.1+ has two `ReplacementMode` interfaces with different integer values. With `SubscriptionProductReplacementParams.setReplacementMode()` always use `BillingFlowParams.ProductDetailsParams.SubscriptionProductReplacementParams.ReplacementMode` (CHARGE_FULL_PRICE=4, DEFERRED=5, KEEP_EXISTING=6). The older `BillingFlowParams.SubscriptionUpdateParams.ReplacementMode` (CHARGE_FULL_PRICE=5, DEFERRED=6) still compiles against the same int parameter but picks the wrong mode, so never import it next to product level params. `UNKNOWN_REPLACEMENT_MODE` is a placeholder; do not select it. The five modes you actually pick from are listed below, along with `KEEP_EXISTING` which arrived in PBL 8.1 for add on bundles.

### Mode Decision Table

Use this table to map your Phase 1 answers to a mode.

| Scenario | Recommended Mode | Immediate Charge? | Access Switch |
|---|---|---|---|
| Upgrade to a higher tier (Google's recommendation) | `CHARGE_PRORATED_PRICE` | Yes, prorated difference | Immediate, renewal unchanged |
| Upgrade, credit the remaining time instead of charging now | `WITH_TIME_PRORATION` | No | Immediate, renewal shifts forward |
| Switch to or from a prepaid plan | `CHARGE_FULL_PRICE` | Yes, full new price | Immediate |
| Upgrade during a free trial or intro price | `WITHOUT_PRORATION` | No, settles at next renewal | Immediate, trial preserved |
| Downgrade | `DEFERRED` | No | At next renewal |
| Add an add on, keep the current item unchanged | `KEEP_EXISTING` on the current item | Prorated charge for the new add on | Add on immediate, current item untouched |

For add ons, pass every active item you keep plus the new add on in `setProductDetailsParamsList` (current base item first). On each kept item, set `SubscriptionProductReplacementParams` with `setOldProductId(<the same product id>)` and `KEEP_EXISTING`, and do not set an offer token. The new add on gets no replacement params. Still set `SubscriptionUpdateParams.setOldPurchaseToken`. Leaving an active item out of the list schedules it for removal. All items must be auto renewing with the same billing period.

Three rules keep you out of trouble:

- `CHARGE_PRORATED_PRICE` only works for upgrades. Using it on a downgrade makes the billing flow fail because Google does not refund through proration.
- `CHARGE_FULL_PRICE` is required when switching to a prepaid plan; from prepaid to auto renewing within the same subscription, `CHARGE_FULL_PRICE` or `WITHOUT_PRORATION`.
- Within the same subscription (switching base plans or offers of one Product ID) to an auto renewing plan, only `CHARGE_FULL_PRICE` or `WITHOUT_PRORATION` are accepted; anything else fails the purchase. Installment to non installment within one subscription is not allowed. The other rows of the table apply to switches between different subscriptions.

### Trade offs to Communicate in Your UI

Each mode has a user facing surprise you need to preempt:

- `WITH_TIME_PRORATION` shortens the next renewal interval on upgrades. Show the new renewal date.
- `CHARGE_PRORATED_PRICE` posts a small charge now. Show the amount before launching the flow.
- `CHARGE_FULL_PRICE` posts the full new price now. Do not hide this behind a generic confirmation.
- `WITHOUT_PRORATION` gives paid access until next renewal. Outside trials this is revenue you chose to give away.
- `DEFERRED` delays the switch. Tell the user "You will switch to Basic on <date>" using the current line item's `expiryTime`.

### The Play Console Default

You can configure a default replacement mode per subscription in Play Console under Monetize > Subscriptions. Each base plan's "Base plan and offer changes" setting (charge immediately = `CHARGE_FULL_PRICE`, or at next billing date = `WITHOUT_PRORATION`) only applies to switches and resubscribes within the same subscription when the client sets no mode; it never applies to a switch to a different subscription. Treat it as a safety net, not a substitute for setting the mode explicitly in code.

## Phase 3: Wire Up SubscriptionProductReplacementParams

Starting with PBL 8.1, `SubscriptionUpdateParams.setSubscriptionReplacementMode()` is deprecated. Set the mode per product with `SubscriptionProductReplacementParams` on the new product's `ProductDetailsParams`, and keep passing the old purchase token through `SubscriptionUpdateParams.setOldPurchaseToken()`. Do not also call `setSubscriptionReplacementMode()`: if both are set, `launchBillingFlow()` returns `DEVELOPER_ERROR` (debug message "...cannot be called at the same time.").

Build the replacement params with the mode you picked in Phase 2, attach them to the new product's `ProductDetailsParams`, and keep the old purchase token on `SubscriptionUpdateParams`. The example below implements an upgrade to a higher tier with Google's recommended `CHARGE_PRORATED_PRICE`, which keeps the billing date stable.

```kotlin
val replacement = BillingFlowParams.ProductDetailsParams
    .SubscriptionProductReplacementParams.newBuilder()
    .setOldProductId(currentProductId) // product being replaced
    .setReplacementMode(
        BillingFlowParams.ProductDetailsParams.SubscriptionProductReplacementParams
            .ReplacementMode.CHARGE_PRORATED_PRICE
    )
    .build()

val productParams = BillingFlowParams.ProductDetailsParams.newBuilder()
    .setProductDetails(premiumDetails)
    .setOfferToken(premiumOfferToken)
    .setSubscriptionProductReplacementParams(replacement)
    .build()

val flowParams = BillingFlowParams.newBuilder()
    .setProductDetailsParamsList(listOf(productParams))
    .setSubscriptionUpdateParams(
        BillingFlowParams.SubscriptionUpdateParams.newBuilder()
            .setOldPurchaseToken(currentPurchaseToken)
            .build()
    )
    .build()

billingClient.launchBillingFlow(activity, flowParams)
```

The structural change from the deprecated setter is that per product replacement data rides with the product, while the old purchase token still rides with the flow. That shape matches what you are saying: "I want this product, and it should replace this existing subscription, using this old token."

### Handling the Result

`PurchasesUpdatedListener` receives a new `Purchase` with a new purchase token. Send that token to your backend. Your server then calls `purchases.subscriptionsv2.get` and inspects `linkedPurchaseToken`:

```kotlin
fun handleNewPurchaseToken(newToken: String) {
    val subscription = playApi
        .getSubscriptionV2(packageName, newToken)
    when (subscription.subscriptionState) {
        "SUBSCRIPTION_STATE_PENDING",
        "SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED" -> return // pending: keep the old token entitled
    }
    val linked = subscription.linkedPurchaseToken
    if (linked != null) {
        database.markReplaced(linked)
    }
    database.insertSubscription(
        purchaseToken = newToken,
        // DEFERRED: the incoming item has no expiryTime yet, so record the current one
        productId = subscription.lineItems.first { it.expiryTime != null }.productId,
        status = subscription.subscriptionState
    )
}
```

Walk the chain if you may have missed prior notifications: the linked token might itself have been replaced by an even older token you still show as active.

### Deferred Mode Specifics

With `DEFERRED`, the new token arrives immediately but carries two line items: the current plan (future `expiryTime`, plus a `deferredItemReplacement` naming the upcoming product) and the new plan (no `expiryTime` yet). Grant entitlement based on the current line item and schedule the switch for the expiry time:

```kotlin
for (item in subscription.lineItems) {
    val pending = item.deferredItemReplacement ?: continue
    currentProductId = item.productId
    upcomingProductId = pending.productId
    switchAt = item.expiryTime
}
```

When the renewal fires, Google sends an RTDN and you promote the pending plan to active.

## Verification Checklist

Before shipping a plan change flow, confirm all of the following:

- You set `oldPurchaseToken` on `SubscriptionUpdateParams` and `oldProductId` on `SubscriptionProductReplacementParams` from the active subscription, not a stale cached value.
- The replacement mode matches the direction and promotional state from Phase 1.
- You do not pass `CHARGE_PRORATED_PRICE` for downgrades.
- `CHARGE_FULL_PRICE` is required when switching to a prepaid plan; from prepaid to auto renewing within the same subscription, `CHARGE_FULL_PRICE` or `WITHOUT_PRORATION`.
- Your backend reads `linkedPurchaseToken` and marks the old record replaced before activating the new one.
- For `DEFERRED`, your UI surfaces the scheduled switch date from the current line item's `expiryTime`.
- You acknowledge the new purchase on your backend after verification.

## References

- [Full chapter](https://www.revenuecat.com/guides/google-play-billing/subscription-upgrades-downgrades-and-plan-changes)
