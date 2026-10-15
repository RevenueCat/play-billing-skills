---
name: catalog-management
description: Use this skill when managing Google Play product and subscription catalogs programmatically with the Google Play Developer API. Covers create, update, activation, deactivation, and deletion for monetization.onetimeproducts, monetization.subscriptions, and legacy inappproducts endpoints, plus regional pricing automation.
license: Apache-2.0; see LICENSE
metadata:
  author: RevenueCat
  source: google-play-handbook chapter 17
  keywords:
  - android
  - play-billing
  - catalog
  - google-play-developer-api
  - inappproducts
  - monetization-subscriptions
---

# Catalog Management

Manage Google Play product catalogs at scale through the Android Publisher API. This skill helps you choose between Play Console and API based workflows, wire up the right endpoints for one time products and subscriptions, and keep regional pricing in sync with your source of truth.

## Phase 1: Discovery

Confirm the basics before writing catalog code.

1. **Service account permission.** The service account must hold **Manage store presence** ("Edit pricing, in-app products, and pricing templates") on every app you manage. Without it, write calls to `inappproducts`, `monetization.onetimeproducts`, and `monetization.subscriptions` return 403. Verify in Play Console under Users and permissions, then grant app level access to every package you intend to manage.
2. **API product surface.** Identify which endpoint family each SKU currently lives under. Catalogs only ever managed in Play Console were migrated automatically and live under `monetization.onetimeproducts`, as do products created through that service. Products created or managed through the `inappproducts` service stay there until you migrate them (an update through `monetization.onetimeproducts` migrates them). Once migrated, the legacy surface stops serving that product.
3. **Existing catalog shape.** List the current catalog with `monetization.onetimeproducts.list` and `monetization.subscriptions.list`. Record product IDs, base plan IDs, offer IDs, and activation state so you know what you are mutating.
4. **Quota posture.** Review quota usage in the Google Cloud Console under APIs and Services > Quotas for the Google Play Android Developer API. The three tiers you depend on are the per minute query limit, the hourly modification limit, and the hourly latency sensitive modification limit.

## Phase 2: Plan

Choose the management model that matches your scale.

| Catalog size | Recommended surface | Notes |
|---|---|---|
| Under 100 products, rare changes | Play Console UI | No automation overhead. Manual review before every change. |
| 100 to 10,000 products | `batchUpdate` with `allowMissing=true`, latency tolerant | Chunks of 100 clear the full catalog in minutes. |
| Over 10,000 products | `batchUpdate` with pacing, latency tolerant | Add inter batch delay, schedule off peak, run dry runs locally. |

Pick the right update mechanism per operation:

- Use `patch` with an `updateMask` for targeted field changes on a single product.
- Use `monetization.subscriptions.batchUpdate` for subscriptions and their nested base plans. Offers are a separate resource: write them with `monetization.subscriptions.basePlans.offers.batchUpdate` (or `create`) and activate them with `offers.activate` or `offers.batchUpdateStates`; new offers stay DRAFT until activated.
- Use `inappproducts.update` only when you want to replace an entire legacy product resource and you send every field.

Plan the activation state explicitly. Base plans created through the API start in DRAFT. Users cannot purchase until you call `monetization.subscriptions.basePlans.activate`. One time products work the same way for new purchase options: a purchase option that has never been activated stays in Draft, invisible to the Play Billing Library, until you activate it with `purchaseOptions.batchUpdateStates` (and its offers with `purchaseOptions.offers.activate`). Updating a product never changes the state of its existing purchase options. Write the activation step into your runbook so you do not ship dark products.

Plan reconciliation before you plan writes. Define a policy for each diff class:

- Missing remotely: create via batch with `allowMissing=true`.
- Divergent: update via batch with the narrowest `updateMask` your system manages.
- Missing locally: deactivate or delete based on whether any base plan has ever been activated.

Add a safety rail: if a reconciliation run proposes changes to more than a threshold percentage of the catalog, fail closed and require manual review.

## Phase 3: Execute

### Endpoint reference

| Capability | One time product | Subscription |
|---|---|---|
| Create | `monetization.onetimeproducts.patch` or `batchUpdate` with `allowMissing=true` (there is no `create`) | `monetization.subscriptions.create` |
| Targeted update | `monetization.onetimeproducts.patch` | `monetization.subscriptions.patch` |
| Bulk create/update | `monetization.onetimeproducts.batchUpdate` | `monetization.subscriptions.batchUpdate` |
| List | `monetization.onetimeproducts.list` | `monetization.subscriptions.list` |
| Delete | `monetization.onetimeproducts.delete` / `batchDelete` | `monetization.subscriptions.delete` (only if never activated) |
| Activate | `monetization.onetimeproducts.purchaseOptions.batchUpdateStates` (`activatePurchaseOptionRequest`); offers: `purchaseOptions.offers.activate` | `monetization.subscriptions.basePlans.activate` |
| Deactivate | `purchaseOptions.batchUpdateStates` (`deactivatePurchaseOptionRequest`); offers: `purchaseOptions.offers.deactivate` | `monetization.subscriptions.basePlans.deactivate` |
| Activate offer | `purchaseOptions.offers.activate` (see Activate row) | `monetization.subscriptions.basePlans.offers.activate` |
| Price migration | n/a | `monetization.subscriptions.basePlans.migratePrices` |

### Create or update a one time product in bulk

```kotlin
val request = BatchUpdateOneTimeProductsRequest().apply {
    requests = chunk.map { product ->
        UpdateOneTimeProductRequest().apply {
            oneTimeProduct = product
            allowMissing = true
            updateMask = "listings,purchaseOptions,taxAndComplianceSettings"
            // Required. Use the regionVersion.version returned by monetization.convertRegionPrices.
            regionsVersion = RegionsVersion().setVersion(currentRegionsVersion)
            latencyTolerance =
                "PRODUCT_UPDATE_LATENCY_TOLERANCE_LATENCY_TOLERANT"
        }
    }
}
androidPublisher.monetization()
    .onetimeproducts()
    .batchUpdate(packageName, request)
    .execute()
```

Send chunks of 100. Each batch counts as one query against the per minute and hourly modification tiers.

### Patch a subscription listing

```kotlin
val subscription = Subscription().apply {
    listings = listOf(
        SubscriptionListing().apply {
            languageCode = "en-US"
            title = "Premium Plan"
            description = "Access all premium features"
        }
    )
}
androidPublisher.monetization().subscriptions()
    .patch(packageName, productId, subscription)
    .setUpdateMask("listings")
    .setRegionsVersionVersion(currentRegionsVersion)
    .execute()
```

Every `patch` needs the `regionsVersion.version` query parameter (Java client: `setRegionsVersionVersion(...)`); in `batchUpdate` it goes in each request's `regionsVersion` field. Use the `regionVersion.version` returned by `monetization.convertRegionPrices`.

### Activate a base plan

```kotlin
androidPublisher.monetization().subscriptions()
    .basePlans()
    .activate(
        packageName, productId, basePlanId,
        ActivateBasePlanRequest()
    )
    .execute()
```

A subscription is not purchasable until at least one base plan is activated.

### Archive rather than delete

For one time products, prefer removing them from your storefront while leaving the catalog entry intact, so restore flows still resolve product IDs. Only call `monetization.onetimeproducts.delete` when you are sure no restore path references the product.

For subscriptions, deactivate all base plans to stop new signups while existing subscribers continue renewing:

```kotlin
androidPublisher.monetization().subscriptions()
    .basePlans()
    .deactivate(
        packageName, productId, basePlanId,
        DeactivateBasePlanRequest()
    )
    .execute()
```

Delete the subscription itself only when no base plan has ever been activated. After activation, deactivation is the terminal state.

### Regional pricing automation

Regional price updates are high volume operations, so route them through batch methods with latency tolerant mode. Build the region map with `monetization.convertRegionPrices` (POST `applications/{packageName}/pricing:convertRegionPrices`), which applies Play's country pricing patterns and returns the `regionVersion` to send as `regionsVersion`, then submit `batchUpdate` calls of up to 100 products per request.

New prices apply to new subscribers only. Moving existing subscribers with `monetization.subscriptions.basePlans.migratePrices` is a price change that Google announces to them; for increases, choose `priceIncreaseType` deliberately (opt in increases cancel subscribers who do not accept). Do not run it automatically after a price sync. See the [price-changes](../price-changes/) skill.

### Handle quota errors

On HTTP 429 with `reason: rateLimitExceeded`, back off exponentially and resume. Keep batches at latency tolerant mode whenever visibility within 24 hours is acceptable, which keeps the hourly latency sensitive tier free for real time fixes like pricing corrections.

## References

- [Full chapter](https://www.revenuecat.com/guides/google-play-billing/managing-your-product-catalog-at-scale)
