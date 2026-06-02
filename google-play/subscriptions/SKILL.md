---
name: subscriptions
description: Use this skill when modeling Google Play subscriptions (the three tier Subscription, Base Plan, Offer hierarchy), choosing a catalog shape, and deciding how to map your paywall to base plans and offers. Grounded in Play Billing Library 9.x.
license: Apache-2.0; see LICENSE
metadata:
  author: RevenueCat
  source: google-play-handbook chapter 4
  keywords:
  - android
  - play-billing
  - subscriptions
  - base-plan
  - offer
  - subscription-hierarchy
---

# Subscriptions

Google Play models every subscription as three nested objects: Subscription, Base Plan, and Offer. The catalog you build in the Play Console must match the catalog your app queries and the paywall your users see. This skill guides you through the hierarchy, helps you pick a catalog shape, and shows how to query and launch the right offer with Play Billing Library 9.x.

## Phase 0: Intent

Confirm the goal before you touch the Play Console or write code. Answer these questions first.

| Question | Why it matters |
| --- | --- |
| What product are you selling? | One Subscription per logical entitlement (Premium, Cloud Storage, etc). |
| How many billing periods? | Each billing period becomes a separate Base Plan under that Subscription. |
| Do you need trials, intro pricing, upgrade incentives, or win back? | Offers attach to Base Plans. Prepaid Base Plans cannot carry Offers. |
| Who decides who qualifies for an offer? | Google managed eligibility for new customer trials, developer determined for everything else. |
| Do you have add ons? | Each add on is a separate Subscription. Your backend, not Google, enforces the parent relationship. |

Stop here if the answer to "what are we actually selling" is not yes or no clear. Modeling a fuzzy catalog locks you into Product IDs that you cannot rename later.

## Phase 1: Discovery

Inspect the current state before you design the catalog.

1. List every entitlement your app grants. Each entitlement typically maps to one Subscription.
2. List every price point you want to charge (monthly, yearly, prepaid 30 day, installment 12 month, etc). Each price point maps to a Base Plan.
3. List every promotion you want to run (free trial, intro price, loyalty discount, win back, upgrade incentive). Each promotion maps to an Offer on a specific Base Plan.
4. Pull the existing catalog from the Play Console under Monetize, Products, Subscriptions. Note any Product IDs already in use. Product IDs are permanent and cannot be reused.
5. Check which markets you ship to. Installment plans are only available in Brazil, France, Italy, and Spain. Prepaid plans are often expected in markets with low credit card penetration.

Flag any mismatch between what the app currently queries and what the Play Console contains. A common source of bugs is a Base Plan or Offer that exists in code but was never activated in the console.

## Phase 2: Plan

Decide the catalog shape. These are the decisions you must make before creating anything in the Play Console.

### How many Subscriptions

One Subscription per distinct entitlement. If Premium and Cloud Storage unlock different features, they are two Subscriptions. If Premium Monthly and Premium Yearly unlock the same features, they are one Subscription with two Base Plans.

### How many Base Plans per Subscription

Add one Base Plan per billing period or plan type you want to sell under that Subscription.

| Plan type | Use when | Offers allowed |
| --- | --- | --- |
| Auto renewing | Standard recurring subscription. Google charges at each period end until cancellation. | Yes |
| Prepaid | User pays upfront for a fixed window. No auto renew, no grace period, no account hold. | No |
| Installment | User commits to N monthly payments, then rolls to month to month. Brazil, France, Italy, Spain only. | Yes |

A Subscription with a monthly auto renewing plan and a yearly auto renewing plan is the typical paywall shape. Add a prepaid plan if your market needs it. Add an installment plan only if you ship to a supported market.

### How to model trials and intro offers

Offers attach to a single Base Plan. Each Offer has an ordered list of pricing phases. You can stack up to two pricing phases before the full Base Plan price takes over.

| Pattern | Phase 1 | Phase 2 | Eligibility |
| --- | --- | --- | --- |
| Free trial | Free for N days | (skip) | New customer acquisition (Google managed) |
| Intro price | Discounted for N periods | (skip) | New customer acquisition or developer determined |
| Trial then intro | Free for N days | Discounted for N periods | New customer acquisition |
| Loyalty discount | Discounted for N periods | (skip) | Developer determined (tagged) |
| Win back | Discounted for N periods | (skip) | Configured as win back in console |

Pick Google managed eligibility for new customer trials. Pick developer determined eligibility when your backend decides (loyalty, cohorts, cross product, custom win back logic). Tag developer determined offers so your app can filter on `offerTags`.

### Decision checklist

Before leaving this phase you should be able to fill in this table for every product.

| Subscription Product ID | Base Plan ID | Plan type | Offer ID | Eligibility | Pricing phases |
| --- | --- | --- | --- | --- | --- |
| premium | monthly | auto renewing | free-trial | New customer | 7 days free |
| premium | monthly | auto renewing | intro-3mo | New customer | 2.99 for 3 months |
| premium | yearly | auto renewing | (none) | n/a | full price |
| premium | prepaid-monthly | prepaid | (none) | n/a | full price |

If a row is unclear, go back to Phase 1 and clarify before creating the product.

## Phase 3: Execute

### Play Console setup (mirror of your Phase 2 plan)

1. Go to Monetize, Products, Subscriptions. Click Create subscription.
2. Enter the Product ID from your plan. It is permanent. Enter Name, Description, and benefits.
3. Save the Subscription. It is an empty container until you add Base Plans.
4. For each Base Plan row in your table, click Add base plan. Enter the Base Plan ID, pick the plan type, pick the billing period, set the default price. For installment plans, set the commitment count. Activate the Base Plan.
5. For each Offer row, open the parent Base Plan, click Add offer, enter the Offer ID, set the eligibility, add the pricing phases in order, activate the Offer.
6. Activate the Subscription itself once at least one Base Plan is active. Allow a few minutes for propagation.

### Code that queries the hierarchy

Query product details once per Subscription you want to show.

```kotlin
val params = QueryProductDetailsParams.newBuilder()
    .setProductList(
        listOf(
            QueryProductDetailsParams.Product.newBuilder()
                .setProductId("premium")
                .setProductType(ProductType.SUBS)
                .build()
        )
    )
    .build()

val result = billingClient.queryProductDetails(params)
val details = result.productDetailsList?.firstOrNull()
```

Read the offer list. Every Base Plan without an Offer still produces one `SubscriptionOfferDetails` entry (the full price entry).

```kotlin
val offerDetails = details
    ?.subscriptionOfferDetails
    ?: emptyList()

offerDetails.forEach { offer ->
    val basePlanId = offer.basePlanId
    val offerId = offer.offerId
    val tags = offer.offerTags
    val phases = offer.pricingPhases.pricingPhaseList
}
```

Filter by developer determined eligibility tags returned from your backend.

```kotlin
val eligible = offerDetails.filter { offer ->
    val tags = offer.offerTags
    tags.isEmpty() || tags.any { it in userEligibleTags }
}
```

Detect a prepaid plan by checking that every pricing phase is non recurring.

```kotlin
val isPrepaid = offer.pricingPhases.pricingPhaseList
    .all { it.recurrenceMode == RecurrenceMode.NON_RECURRING }
```

Detect an installment plan by reading `installmentPlanDetails`.

```kotlin
val installment = offer.installmentPlanDetails
val commitmentCount = installment?.commitmentPaymentsCount
val renewalCount = installment?.subsequentCommitmentPaymentsCount
```

Launch the billing flow with the selected offer token. Every purchase requires a token, including Base Plans without Offers.

```kotlin
val productParams = BillingFlowParams.ProductDetailsParams.newBuilder()
    .setProductDetails(details)
    .setOfferToken(chosenOffer.offerToken)
    .build()

val flowParams = BillingFlowParams.newBuilder()
    .setProductDetailsParamsList(listOf(productParams))
    .build()

billingClient.launchBillingFlow(activity, flowParams)
```

## Phase 4: Verify

Prove the catalog and the code agree before you ship.

1. Confirm every Product ID, Base Plan ID, and Offer ID in your Phase 2 table exists and is active in the Play Console.
2. Run `queryProductDetails` on a signed build and log every `SubscriptionOfferDetails` entry. Check that `basePlanId` and `offerId` values match your table.
3. For each Offer, confirm the pricing phases in the response match what you configured. A missing phase usually means the Offer is not active.
4. Walk through every paywall path and confirm your code passes a non null `offerToken`. Missing tokens cause the billing flow to fail.
5. Test developer determined eligibility by returning an empty tag set from your backend and confirming tagged Offers drop out of the UI.
6. Test a prepaid purchase end to end if you sell one. Confirm your app extends entitlement on top up rather than treating the second purchase as a new subscription.
7. Confirm initial purchases are acknowledged within 3 days (and within the plan duration for prepaid plans shorter than 3 days). Server side acknowledgement after RTDN processing is the safer default.
8. If you sell installment plans in Brazil, France, Italy, or Spain, test the purchase dialog in that locale and confirm the commitment count is communicated to the user.

## References

- [Full chapter](https://www.revenuecat.com/guides/google-play-billing/subscriptions-deep-dive)

- Play Billing Library 9.x `ProductDetails`, `SubscriptionOfferDetails`, `BillingFlowParams.ProductDetailsParams`.
- Play Console: Monetize, Products, Subscriptions.
