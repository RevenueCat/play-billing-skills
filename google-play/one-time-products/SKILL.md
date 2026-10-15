---
name: one-time-products
description: Use this skill when implementing, acknowledging, or consuming Google Play one time products (consumables and non consumables) with the Play Billing Library. Covers launch, pending transactions, consume for consumables, acknowledge for non consumables.
license: Apache-2.0; see LICENSE
metadata:
  author: RevenueCat
  source: google-play-handbook chapter 3
  keywords:
  - android
  - play-billing
  - one-time-products
  - consumable
  - non-consumable
  - acknowledge
  - consume
---

# One Time Products

Build a complete Google Play one time product integration with Play Billing Library 9.x. This skill walks through the full lifecycle: querying, launching, handling pending state, and finishing with either consume or acknowledge.

## Phase 0: Intent

Confirm what you are building before writing code. Answer these questions:

- What product type is this? Consumable (repeatable like coins) or non consumable (one time like remove ads)?
- Where does fulfillment happen? Server side verification plus server side consume or acknowledge is the reliable pattern. Client side is acceptable only during early development.
- Which PBL version is the app on? PBL 9.x is assumed. Pending purchases for one time products are enabled explicitly by passing `PendingPurchasesParams.newBuilder().enableOneTimeProducts().build()` to `enablePendingPurchases()` (required since PBL 8.0; the parameterless overload was removed in 8.0).
- Do you need multi quantity, pre order, or multiple offers on the same product?

If any answer is unclear, stop and gather the requirements. Do not ship a purchase flow with ambiguous fulfillment rules.

## Phase 1: Discovery

Gather the facts that drive the implementation.

| Discovery item | Where to find it |
| --- | --- |
| Product IDs | Play Console, Monetize with Play > Products > One-time products (In-app products on consoles still on the legacy model) |
| Product state | Must be Active before the app can query or sell |
| Pricing and availability | Play Console product page |
| Tax category | Play Console product page |
| PBL version | App's `build.gradle` billing dependency |
| Backend verification endpoint | Your server code or API spec |
| RTDN subscription | Cloud Pub/Sub topic with "Get all notifications for subscriptions and one-time products" selected in Play Console (otherwise `ONE_TIME_PRODUCT_PURCHASED` and `ONE_TIME_PRODUCT_CANCELED` are not sent) |

Choose naming up front. Good patterns: `coins_100`, `remove_ads`, `level_pack_desert`. Avoid `product_1` or `item_a`. Product IDs are permanent and cannot be reused after deletion.

## Phase 2: Plan

Decide consumable vs non consumable. The choice drives which API you call after granting entitlement.

| Question | Consumable | Non consumable |
| --- | --- | --- |
| Can the user buy it again? | Yes | No |
| Typical examples | Coins, lives, boosts | Remove ads, theme pack, level unlock |
| Finalize call | `consumePurchase()` | `acknowledgePurchase()` |
| Stays in purchase history? | No (after consume) | Yes |
| Good fit for multi quantity? | Often | No |

Google Play does not enforce this split at the product configuration level. A product becomes consumable because your code calls `consumePurchase()` on it.

Plan the end to end flow before writing code:

1. Query products with `queryProductDetailsAsync()`.
2. Display products using `formattedPrice`.
3. Launch purchase with `launchBillingFlow()` from an `Activity`.
4. Receive result through `PurchasesUpdatedListener`.
5. Route by `purchaseState`: `PURCHASED`, `PENDING`, or `UNSPECIFIED_STATE`.
6. Verify on your server with the Google Play Developer API.
7. Grant entitlement.
8. Consume (consumable) or acknowledge (non consumable) within 3 days. Aim for seconds.
9. Catch missed purchases with `queryPurchasesAsync()` on launch and resume.

## Phase 3: Execute

### Query product details

One time products use `ProductType.INAPP`. Always check the `BillingResult` response code before reading the list.

```kotlin
suspend fun queryOneTimeProducts(
    billingClient: BillingClient
): List<ProductDetails> {
    val productList = listOf(
        QueryProductDetailsParams.Product.newBuilder()
            .setProductId("coins_100")
            .setProductType(ProductType.INAPP)
            .build()
    )
    val params = QueryProductDetailsParams.newBuilder()
        .setProductList(productList)
        .build()
    val result = billingClient.queryProductDetails(params)
    return result.productDetailsList.orEmpty()
}
```

Use `formattedPrice` directly. It is already localized.

```kotlin
fun displayProduct(productDetails: ProductDetails) {
    val name = productDetails.name
    val description = productDetails.description
    val price = productDetails
        .oneTimePurchaseOfferDetails
        ?.formattedPrice
}
```

A product can have several purchase options (buy, rent) and offers (discount, pre order). Read `productDetails.oneTimePurchaseOfferDetailsList` to list them; `oneTimePurchaseOfferDetails` returns only the backwards compatible buy option. Each entry has `offerToken`, `formattedPrice`, and `rentalDetails`, `preorderDetails`, or `discountDisplayInfo` when applicable.

### Launch the purchase flow

`launchBillingFlow()` needs an `Activity`. Only one flow can be active at a time.

```kotlin
fun launchPurchase(
    activity: Activity,
    billingClient: BillingClient,
    productDetails: ProductDetails
): BillingResult {
    val productDetailsParams =
        BillingFlowParams.ProductDetailsParams
            .newBuilder()
            .setProductDetails(productDetails)
            .build()
    val flowParams = BillingFlowParams.newBuilder()
        .setProductDetailsParamsList(
            listOf(productDetailsParams)
        )
        .build()
    return billingClient.launchBillingFlow(
        activity, flowParams
    )
}
```

Attach hashed identifiers for fraud detection and backend correlation. Never pass raw user IDs.

```kotlin
val flowParams = BillingFlowParams.newBuilder()
    .setProductDetailsParamsList(listOf(productDetailsParams))
    .setObfuscatedAccountId(hashedUserId)
    .setObfuscatedProfileId(hashedProfileId)
    .build()
```

### Receive the purchase result

```kotlin
private val listener =
    PurchasesUpdatedListener { result, purchases ->
        when (result.responseCode) {
            BillingResponseCode.OK ->
                purchases?.forEach { handlePurchase(it) }
            BillingResponseCode.USER_CANCELED -> {
                // User dismissed the purchase dialog
            }
            else -> {
                // Log and surface an error
            }
        }
    }
```

### Route by purchase state

Never grant, consume, or acknowledge a `PENDING` purchase. A pre order stays `PENDING` until its release time, then becomes `PURCHASED` on its own; show pre order messaging, not a payment prompt (pre orders are in Early Access).

```kotlin
fun handlePurchase(purchase: Purchase) {
    when (purchase.purchaseState) {
        Purchase.PurchaseState.PURCHASED ->
            verifyAndGrantEntitlement(purchase)
        Purchase.PurchaseState.PENDING ->
            showPendingMessage(purchase)
        Purchase.PurchaseState.UNSPECIFIED_STATE -> {
            // Log and investigate
        }
    }
}
```

### Consume a consumable

`consumePurchase()` finalizes the purchase and removes it from history so the user can buy it again. Consume from your server when possible.

```kotlin
suspend fun consumePurchase(
    billingClient: BillingClient,
    purchaseToken: String
) {
    val params = ConsumeParams.newBuilder()
        .setPurchaseToken(purchaseToken)
        .build()
    val result = billingClient.consumePurchase(params)
    if (result.billingResult.responseCode
        == BillingResponseCode.OK
    ) {
        // Purchase consumed
    }
}
```

### Acknowledge a non consumable

Check `purchase.isAcknowledged` first. Calling acknowledge twice returns an error.

```kotlin
suspend fun acknowledgePurchase(
    billingClient: BillingClient,
    purchaseToken: String
) {
    val params = AcknowledgePurchaseParams.newBuilder()
        .setPurchaseToken(purchaseToken)
        .build()
    val result = billingClient.acknowledgePurchase(params)
    if (result.responseCode == BillingResponseCode.OK) {
        // Purchase acknowledged
    }
}
```

### Handle multi quantity

Always read `purchase.quantity`. For single quantity purchases the value is 1, so the code stays compatible.

```kotlin
suspend fun handleMultiQuantityPurchase(purchase: Purchase) {
    val quantity = purchase.quantity
    grantCoins(userId, quantity * COINS_PER_PACK)
    consumePurchase(billingClient, purchase.purchaseToken)
}
```

### Launch a specific offer

When a product has multiple offers, pass the token of the entry the user chose in `oneTimePurchaseOfferDetailsList`, unwrapped: `requireNotNull(offer.offerToken)` (the getter is nullable).

```kotlin
fun launchPurchaseWithOffer(
    activity: Activity,
    billingClient: BillingClient,
    productDetails: ProductDetails,
    offerToken: String
): BillingResult {
    val params = BillingFlowParams.ProductDetailsParams
        .newBuilder()
        .setProductDetails(productDetails)
        .setOfferToken(offerToken)
        .build()
    val flowParams = BillingFlowParams.newBuilder()
        .setProductDetailsParamsList(listOf(params))
        .build()
    return billingClient.launchBillingFlow(
        activity, flowParams
    )
}
```

### Catch missed purchases

Call `queryPurchasesAsync()` on app launch, on `BillingClient` reconnect, and on `onResume()`.

```kotlin
suspend fun queryExistingPurchases(
    billingClient: BillingClient
): List<Purchase> {
    val params = QueryPurchasesParams.newBuilder()
        .setProductType(ProductType.INAPP)
        .build()
    val result = billingClient.queryPurchasesAsync(params)
    return result.purchasesList
}
```

### Back end verification

The server flow for each `PURCHASED` purchase:

1. Receive the purchase token from the client.
2. Call `purchases.productsv2.getproductpurchasev2` (or `purchases.products.get`) with the token.
3. Confirm the purchase state, product ID, and quantity. To check the amount paid, call `orders.get` with the order ID.
4. Record the entitlement in your database.
5. Call `purchases.products.consume` or `purchases.products.acknowledge`.
6. Return success to the client only after the finalize call succeeds.

Pair this with RTDN handling so your backend stays in sync with pending transitions and refunds.

## Phase 4: Verify

Run these checks before you ship.

| Check | How to verify |
| --- | --- |
| Products load | `queryProductDetails()` returns the expected items with `formattedPrice` populated |
| Purchase flow opens | `launchBillingFlow()` returns `BillingResponseCode.OK` |
| Purchase state routed | Log each `purchaseState` branch hits the right handler |
| Pending handled | Use a test account with a delayed payment method, confirm no entitlement is granted |
| Consume works | After consume, the product returns from `queryPurchasesAsync()` only if repurchased |
| Acknowledge works | `purchase.isAcknowledged` becomes true after the call |
| 3 day window respected | Fulfillment completes in seconds, not days |
| No hardcoded prices | UI reads `formattedPrice` from `ProductDetails` |
| Missed purchases caught | Force close during a purchase, relaunch, confirm `queryPurchasesAsync()` picks it up |
| Server side verification | Every entitlement grant is preceded by a Developer API verification |
| RTDN subscribed | `ONE_TIME_PRODUCT_PURCHASED` and `ONE_TIME_PRODUCT_CANCELED` notifications reach your backend |

Common pitfalls to scan for:

- Only relying on `PurchasesUpdatedListener` and skipping `queryPurchasesAsync()`.
- Consuming before the server recorded the entitlement.
- Granting entitlement on `PENDING`.
- Hardcoding prices in the UI.
- Ignoring `BillingClient` disconnects. Wrap calls in retry logic and check `isReady`.
- Generic product IDs like `product_1`.
- Skipping server side verification entirely.

## References

- [Full chapter](https://www.revenuecat.com/guides/google-play-billing/one-time-products)
