---
name: price-changes
description: Use this skill when changing subscription prices on Google Play. Covers price decreases, opt in versus opt out price increases, the 30 to 37 day notification timeline, the OUTSTANDING price change state, and the API calls to manage price changes for existing subscribers.
license: Apache-2.0; see LICENSE
metadata:
  author: RevenueCat
  source: google-play-handbook chapter 14
  keywords:
  - android
  - play-billing
  - price-change
  - opt-in
  - opt-out
  - price-change-state
---

# Google Play Price Changes

Google Play price changes touch three separate systems: the base plan price itself, the legacy price cohorts holding existing subscribers, and the notification and consent flow that migrates those cohorts. You have to operate each one deliberately.

## Phase 1: Understand

Know what you are actually changing before you touch any API.

- **New subscribers** see the new base plan price within a few hours of the patch call. No further work.
- **Existing subscribers** land in a legacy price cohort and keep paying their original price forever unless you migrate them. Up to 250 cohorts per base plan.
- **Offer pricing phases** (free trial, intro price) cannot be migrated. A change there only affects new subscribers.
- **Installment subscribers** under a commitment cannot have their price migrated until the commitment ends.

Two questions drive everything that follows:

1. Is the new price higher or lower than the legacy cohort price?
2. If higher, do you want opt in (default) or opt out (conditional)?

## Phase 2: Plan

### Decide opt in vs opt out

Price decreases skip this entirely. They apply automatically with email notification and no consent. The decision matters only for increases.

| Dimension | Opt in increase | Opt out increase |
|---|---|---|
| Subscriber consent | Required. Must accept or subscription auto cancels. | Not required. Silent unless user cancels. |
| Freeze period | 7 days of silence before Google notifies users. | None. Google notifies immediately. |
| Notification lead time | 30 days before the user's first renewal at the new price. | 30 or 60 days depending on country. |
| Effective date | 37 days after initiation (7 day freeze + 30 day notice). | 30 or 60 days after initiation. |
| Regional availability | All regions. | Conditional. Subject to per region rules. |
| Frequency cap | None. | One per base plan per country per 365 day rolling window. |
| Amount cap | None. | Per country maximum increase amount. |
| First time requirement | Can start from the API. | First opt out for the app must start in the Play Console. |
| Failure mode | N/A. | Silently downgrades to opt in if eligibility fails. |
| In app notice | Recommended: tell users in app and deep link to the Play subscription screen. | Required: a prominent in app notice at least 30 days before the new price applies (subscription name, current and new price, effective date, how to cancel) on every device type except watches; you certify it in Play Console when you start the increase. |

Pick opt in when you need any region not on the opt out list, when the increase exceeds the regional cap, when you already used your annual opt out for that country, or when you have never done an opt out in this app before.

### Plan the timeline

For an opt in increase, map backward from the target effective date. Add 37 days to your initiation date. During the 7 day freeze, plan your own in app messaging. Google starts sending emails and push notifications on day 7, but each subscriber is notified individually 30 days before their first renewal at the new price (the first renewal on or after day 37).

For an opt out increase, pick 30 or 60 days based on the subscriber's country. There is no freeze. Ship the required in app notice first; it must be live 30 days before the new price applies.

### Plan overlapping migrations

If you initiate a second migration before the first resolves, only the latest applies. The older one transitions to `CANCELED` and fires a `SUBSCRIPTION_PRICE_CHANGE_UPDATED` RTDN. Plan your backend to treat every RTDN as a signal to re fetch, not as a state diff.

## Phase 3: Execute

### Step 1: Patch the base plan price

Updating the base plan itself changes the sticker price for new purchases only. Existing subscribers are untouched. `patch` requires the `updateMask` and `regionsVersion` query parameters, so fetch the subscription first, change only the target region's price inside the existing base plan's `regionalConfigs`, and send the whole subscription back.

```kotlin
val subscription = androidPublisher.monetization().subscriptions()
    .get(packageName, productId)
    .execute()

val basePlan = subscription.basePlans.first { it.basePlanId == basePlanId }
val regionConfig = basePlan.regionalConfigs.first { it.regionCode == "US" }
regionConfig.price = Money().setCurrencyCode("USD").setUnits(6L).setNanos(990_000_000)

androidPublisher.monetization().subscriptions()
    .patch(packageName, productId, subscription)
    .setUpdateMask("basePlans")
    .setRegionsVersionVersion("2022/02") // required regionsVersion.version query parameter
    .execute()
```

Propagation to new purchases is typically under 4 hours. There is no way to force instant propagation, so build in a buffer for time sensitive launches.

### Step 2: Migrate the legacy cohort

This is the action that actually moves existing subscribers. Use `monetization.subscriptions.basePlans.migratePrices` with a `RegionalPriceMigrationConfig` per region.

```kotlin
val migration = RegionalPriceMigrationConfig()
    .setRegionCode("US")
    .setOldestAllowedPriceVersionTime("2025-01-01T00:00:00Z")
    .setPriceIncreaseType("PRICE_INCREASE_TYPE_OPT_IN")
val request = MigrateBasePlanPricesRequest()
    .setRegionalPriceMigrations(listOf(migration))
    .setRegionsVersion(RegionsVersion().setVersion("2022/02"))
androidPublisher.monetization().subscriptions().basePlans()
    .migratePrices(packageName, productId, basePlanId, request)
    .execute()
```

The `oldestAllowedPriceVersionTime` cutoff lets you migrate only cohorts older than a given timestamp. A successful call returns an empty body and queues the migration.

If you request `PRICE_INCREASE_TYPE_OPT_OUT` and the migration fails any eligibility check (region, amount, frequency, first time rule), Google silently downgrades it to opt in. Your API call still succeeds. Watch the resulting RTDN to see which mode actually took effect.

### Step 3: Handle SUBSCRIPTION_PRICE_CHANGE_UPDATED RTDN (type 19)

Every price change event fires this RTDN. Always fetch the current state with `purchases.subscriptionsv2.get` and inspect `autoRenewingPlan.priceChangeDetails` on each line item. Do not assume which migration the notification refers to.

```kotlin
fun handlePriceChangeRtdn(purchaseToken: String) {
    val sub = playApi.getSubscriptionV2(packageName, purchaseToken)
    for (item in sub.lineItems) {
        val pc = item.autoRenewingPlan?.priceChangeDetails ?: continue
        when (pc.priceChangeState) {
            "OUTSTANDING" -> recordPendingOptIn(pc)
            "CONFIRMED"   -> recordAcceptedOrAutomatic(pc)
            "APPLIED"     -> markPriceApplied(pc)
            "CANCELED"    -> clearMigrationState(pc)
        }
    }
}
```

State meanings:

| priceChangeState | What it means |
|---|---|
| `OUTSTANDING` | Opt in increase pending user acceptance. |
| `CONFIRMED` | User accepted, or opt out increase, or decrease. Applies at next renewal. |
| `APPLIED` | Price change already took effect at a renewal. |
| `CANCELED` | Migration canceled by an overlapping change or reversal. |

The `priceChangeMode` field distinguishes `PRICE_DECREASE`, `PRICE_INCREASE` (opt in), and `OPT_OUT_PRICE_INCREASE`. The `expectedNewPriceChargeTime` field tells you when the user will first be charged at the new price and is only populated before the change applies.

### Step 4: Watch for OUTSTANDING opt in increases and auto cancel

For opt in increases, a user who neither accepts nor cancels gets auto canceled by Google at their renewal. The user keeps access through the end of the current period, then the subscription expires. Treat `priceChangeState == OUTSTANDING` past the effective date as a churn risk and surface an in app prompt with a deep link to the Play Store subscription management screen.

### Step 4.1: Confirm the increase in app with showInAppMessages (PBL 9+)

PBL 9 lets the user accept an opt in price increase **without leaving your app**. Google surfaces the consent flow through the existing `showInAppMessages` entry point and the `TRANSACTIONAL` category (the same one used for payment recovery). The message appears starting the first day the user can accept the increase and at most once every 7 days, which raises acceptance and reduces involuntary churn versus a Play Store deep link alone.

```kotlin
// PBL 9.x
fun promptPriceIncrease(activity: Activity) {
    val params = InAppMessageParams.newBuilder()
        .addInAppMessageCategoryToShow(
            InAppMessageParams.InAppMessageCategoryId.TRANSACTIONAL
        ).build()
    billingClient.showInAppMessages(activity, params) { r ->
        if (r.responseCode ==
            InAppMessageResult.InAppMessageResponseCode.SUBSCRIPTION_STATUS_UPDATED
        ) {
            // User accepted the new price in the dialog. Re sync from your backend;
            // the priceChangeState moves to CONFIRMED once the RTDN lands.
            refreshSubscriptionStatus()
        }
    }
}
```

Call this at natural moments (app launch, entering a gated feature) for subscribers whose line item shows `priceChangeState == OUTSTANDING`. On `SUBSCRIPTION_STATUS_UPDATED`, re fetch with `purchases.subscriptionsv2.get` rather than trusting client state. See [payment-recovery](../payment-recovery/) for the same API applied to grace period and account hold.

### Step 5: Handle the payment authorization window on decreases

Google authorizes payment up to 48 hours before renewal in most regions, and up to 5 days before in India and Brazil. A subscriber whose payment was already authorized at the old higher price pays that price for the current cycle. The decrease applies at the following renewal. Do not treat this as a bug.

### Step 6: Recover from accidents quickly

- **Accidental increase**: Patch the price back to the original, then initiate a price decrease migration. If you catch it inside the 7 day opt in freeze, no user was ever notified.
- **Accidental decrease**: Patch the price back up, then initiate an increase migration. If the time to each subscriber's renewal exceeds the country notification window (30 or 60 days), the reversal holds. Otherwise they pay the lower price for one cycle.

### Step 7: Test with Play Billing Lab

Never test price changes on production subscribers. Use the Play Billing Lab app on a license tester device. It compresses renewal and notification timelines from weeks to minutes. Defer billing by at least one hour after applying a test price change so the system can register the notification before the compressed renewal fires.

## References

- [Full chapter](https://www.revenuecat.com/guides/google-play-billing/changing-subscription-prices)
