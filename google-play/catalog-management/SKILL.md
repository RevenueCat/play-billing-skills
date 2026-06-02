---
name: catalog-management
description: Use this skill when managing Google Play product and subscription catalogs programmatically with the Google Play Developer API. Covers create, update, archive for both inappproducts and monetization.subscriptions endpoints, plus regional pricing automation.
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

1. **Service account scope.** The service account attached to your Google Play project must hold the Financial permission (or the legacy equivalent) on the Google Play Console. Without it, `inappproducts`, `monetization.onetimeproducts`, and `monetization.subscriptions` calls return 403. Verify in Play Console under Users and permissions, then grant app level access to every package you intend to manage.
2. **API product surface.** Identify which endpoint family each SKU currently lives under. Products created before the one time product model upgrade live under `inappproducts`. Products created through the new service live under `monetization.onetimeproducts`. Once migrated, the legacy surface stops serving that product.
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
- Use `batchUpdate` for bulk creates and updates, including nested base plans and offers on subscriptions.
- Use `inappproducts.update` only when you want to replace an entire legacy product resource and you send every field.

Plan the activation state explicitly. Base plans created through the API start in DRAFT. Users cannot purchase until you call `monetization.subscriptions.basePlans.activate`. Write the activation step into your runbook so you do not ship dark products.

Plan reconciliation before you plan writes. Define a policy for each diff class:

- Missing remotely: create via batch with `allowMissing=true`.
- Divergent: update via batch with the narrowest `updateMask` your system manages.
- Missing locally: deactivate or delete based on whether any base plan has ever been activated.

Add a safety rail: if a reconciliation run proposes changes to more than a threshold percentage of the catalog, fail closed and require manual review.

## Phase 3: Execute

### Endpoint reference

| Capability | One time product | Subscription |
|---|---|---|
| Create | `monetization.onetimeproducts.create` | `monetization.subscriptions.create` |
| Targeted update | `monetization.onetimeproducts.patch` | `monetization.subscriptions.patch` |
| Bulk create/update | `monetization.onetimeproducts.batchUpdate` | `monetization.subscriptions.batchUpdate` |
| List | `monetization.onetimeproducts.list` | `monetization.subscriptions.list` |
| Delete | `monetization.onetimeproducts.delete` / `batchDelete` | `monetization.subscriptions.delete` (only if never activated) |
| Activate | n/a | `monetization.subscriptions.basePlans.activate` |
| Deactivate | n/a | `monetization.subscriptions.basePlans.deactivate` |
| Price migration | n/a | `monetization.subscriptions.basePlans.migratePrices` |

### Create or update a one time product in bulk

```kotlin
val request = BatchUpdateOneTimeProductsRequest().apply {
    requests = chunk.map { product ->
        UpdateOneTimeProductRequest().apply {
            oneTimeProduct = product
            allowMissing = true
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
    .execute()
```

When patching regional pricing fields, include `regionsVersion` in the body so the call uses the current region configuration.

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

Regional price updates are high volume operations, so route them through batch methods with latency tolerant mode. Build the full region map locally, then submit `batchUpdate` calls of up to 100 products per request. For subscriptions that already have subscribers on older prices, follow the bulk update with `monetization.subscriptions.basePlans.migratePrices` to move existing subscribers onto the new price version.

### Handle quota errors

On HTTP 429 with `reason: rateLimitExceeded`, back off exponentially and resume. Keep batches at latency tolerant mode whenever visibility within 24 hours is acceptable, which keeps the hourly latency sensitive tier free for real time fixes like pricing corrections.

## References

- [Full chapter](https://www.revenuecat.com/guides/google-play-billing/managing-your-product-catalog-at-scale)
