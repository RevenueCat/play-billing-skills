---
name: integrating-pbl
description: Use this skill when integrating the Google Play Billing Library client side (adding the dependency, wiring BillingClient, managing its connection lifecycle, and querying product details). Grounded in PBL 9.x.
license: Apache-2.0; see LICENSE
metadata:
  author: RevenueCat
  source: google-play-handbook chapter 5
  keywords:
  - android
  - play-billing
  - billingclient
  - query-products
  - pbl9
  - connection-lifecycle
---

# Integrating the Play Billing Library

You are wiring the Play Billing Library into an Android app. This skill covers the client side setup: adding the dependency, building `BillingClient`, managing the connection, and querying products. Follow the phases in order.

## Phase 0: Intent

Confirm what the caller actually wants before you touch code. Pick one:

| Intent | Signal |
|---|---|
| First time integration | No `com.android.billingclient` dependency yet |
| Upgrading PBL | Existing `BillingClient` on an older version |
| Fixing connection bugs | `SERVICE_DISCONNECTED`, missing `onBillingSetupFinished` callbacks |
| Adding product queries | `BillingClient` exists, no `queryProductDetailsAsync` call |

If the request is ambiguous, ask. Do not write Gradle edits or Kotlin until you know the target state.

## Phase 1: Discovery

Inspect the project before changing anything.

Check the Gradle setup:

```bash
grep -r "com.android.billingclient" --include="*.gradle*"
```

Check existing BillingClient usage:

```bash
grep -rn "BillingClient" --include="*.kt" --include="*.java" src/
```

Record these facts:

| Fact | Why it matters |
|---|---|
| Current PBL version | Drives migration steps (PBL 8 and 9 require `PendingPurchasesParams`) |
| Context passed to builder | Any context works; BillingClient uses its application context |
| Whether `enablePendingPurchases` is called | Missing call throws `IllegalArgumentException` on `build()` |
| Whether auto reconnection is enabled | Absent means you own retry logic |
| Where `BillingClient` is instantiated | ViewModel, singleton, or Application scoped |
| Whether KTX is on the classpath | Decides callback vs coroutine style |
| compileSdk | PBL 9 needs 35+ (androidx.core 1.15.0) |
| minSdk | PBL 8.1+ needs 23+ |
| Kotlin version | billing-ktx 9.x needs Kotlin 2.2+; on older Kotlin use plain `billing` |

If you find multiple `BillingClient` instances in one process, flag it. One instance per process is the rule.

## Phase 2: Plan

Before writing code, pick a connection strategy and confirm with the caller.

| Strategy | Use when | Trade off |
|---|---|---|
| Application scoped singleton | Billing gates many features, frequent status checks | Connection stays open while idle |
| ViewModel / feature scoped | Billing only appears on one or two screens | Pays setup cost every entry |

Then decide:

1. Callback style or KTX coroutine style. If coroutines are already the norm in the project, pick KTX.
2. Auto reconnection on or off. Default to on unless you need manual control.
3. Which product IDs and types (`INAPP`, `SUBS`) the initial query covers. Batch up to 20 per call.

Write the plan down. One BillingClient owner, one listener, one connection strategy.

## Phase 3: Execute

### Step 1 Add the dependency

In the module `build.gradle.kts`:

```kotlin
dependencies {
    implementation("com.android.billingclient:billing-ktx:9.1.0")
}
```

The `billing-ktx` artifact pulls in the base library plus coroutine extensions. Drop `-ktx` if you do not want KTX. PBL 9.x requires compileSdk 35+ and minSdk 23+; `billing-ktx` 9.x also requires Kotlin 2.2+.

### Step 2 Build the BillingClient

Pass any context (the library uses its application context):

```kotlin
val billingClient = BillingClient.newBuilder(appContext)
    .setListener(purchasesUpdatedListener)
    .enablePendingPurchases(
        PendingPurchasesParams.newBuilder().enableOneTimeProducts().build()
    )
    .enableAutoServiceReconnection()
    .build()
```

`setListener` and `enablePendingPurchases(...enableOneTimeProducts()...)` are required; `build()` throws `IllegalArgumentException` if either is missing. `enableAutoServiceReconnection()` is optional but strongly recommended.

### Step 3 Wire the PurchasesUpdatedListener

One listener per client. Dispatch from it if other components need to react:

```kotlin
val purchasesUpdatedListener =
    PurchasesUpdatedListener { result, purchases ->
        when (result.responseCode) {
            BillingResponseCode.OK ->
                purchases?.forEach(::handlePurchase)
            BillingResponseCode.USER_CANCELED -> Unit
            else -> logError(result)
        }
    }
```

The callback fires on the main thread and can fire while the app is in the background. Update a repository or state holder, not UI directly. Never force unwrap `purchases`; it is null on non OK responses.

### Step 4 Start the connection

Callback form:

```kotlin
billingClient.startConnection(object : BillingClientStateListener {
    override fun onBillingSetupFinished(result: BillingResult) {
        if (result.responseCode == BillingResponseCode.OK) {
            onBillingReady()
        }
    }
    override fun onBillingServiceDisconnected() { /* auto retry */ }
})
```

KTX has no `startConnection` extension. Use the callback form, or wrap it:

```kotlin
suspend fun BillingClient.connect(): BillingResult =
    suspendCancellableCoroutine { cont ->
        startConnection(object : BillingClientStateListener {
            override fun onBillingSetupFinished(result: BillingResult) {
                if (cont.isActive) cont.resume(result)
            }
            override fun onBillingServiceDisconnected() {
                // Resume so the caller never hangs if setup is interrupted
                if (cont.isActive) cont.resume(
                    BillingResult.newBuilder()
                        .setResponseCode(BillingResponseCode.SERVICE_DISCONNECTED)
                        .build()
                )
            }
        })
    }
```

Do not call billing methods before `onBillingSetupFinished` fires with `OK`. Queue pending work and flush on each successful connect.

### Step 5 Query product details

Build one query per product type (`INAPP` and `SUBS` cannot be mixed in one call; the builder throws `IllegalArgumentException`), keeping each batch at or under 20 products:

```kotlin
val products = listOf(
    QueryProductDetailsParams.Product.newBuilder()
        .setProductId("premium_monthly")
        .setProductType(ProductType.SUBS)
        .build()
)
val params = QueryProductDetailsParams.newBuilder()
    .setProductList(products)
    .build()
```

Callback form:

```kotlin
billingClient.queryProductDetailsAsync(params) { result, queryResult ->
    if (result.responseCode == BillingResponseCode.OK) {
        displayProducts(queryResult.productDetailsList)
        handleUnfetched(queryResult.unfetchedProductList)
    }
}
```

KTX form:

```kotlin
val result = billingClient.queryProductDetails(params)
val details = result.productDetailsList.orEmpty()
```

The KTX result has no unfetched list and `productDetailsList` is nullable (use `.orEmpty()`). Use the callback form if you need Step 6.

Do not cache `ProductDetails` across sessions. Prices can change; re query each time you display products.

### Step 6 Handle UnfetchedProduct results

The callback API's `QueryProductDetailsResult` may include `UnfetchedProduct` entries (the KTX `ProductDetailsResult` does not expose them). Branch on `unfetchedProduct.statusCode`:

| `unfetchedProduct.statusCode` | Action |
|---|---|
| `INVALID_PRODUCT_ID_FORMAT` | Do not retry; fix the product ID |
| `PRODUCT_NOT_FOUND` | Check the ID and product type in Play Console; a just created product may still be propagating, so retry later, not in a loop |
| `NO_ELIGIBLE_OFFER` | Product exists but has no available base plan (subs) or purchase option (one time) for this user; hide it |
| `UNKNOWN` | Log and hide |

Retry the whole query with backoff only when the top level `BillingResult` is retriable (`SERVICE_UNAVAILABLE`, `ERROR`, `NETWORK_ERROR`, `SERVICE_DISCONNECTED`). Show the products you did fetch and log the rest.

### Step 7 Handle disconnection

With `enableAutoServiceReconnection()`, PBL re-establishes the connection when you make an API call while disconnected. If a call still returns `SERVICE_DISCONNECTED`, the library could not reconnect; retry that operation (simple retry in session, backoff in the background). If you disabled auto reconnection, implement backoff yourself starting at one second and capping near fifteen seconds.

Check `billingClient.isReady` before issuing a call if you need a fast path. Always call `endConnection()` when the owning scope is destroyed.

## Phase 4: Verify

Before you mark the integration done, confirm each of these:

| Check | How |
|---|---|
| Dependency present | `./gradlew :app:dependencies` lists `billing-ktx` at the target version |
| Single client per process | `grep -rn "BillingClient.newBuilder" src/` returns one call site |
| `enablePendingPurchases` called | Build passes without `IllegalArgumentException` at first `build()` |
| Listener fires on purchase | Run a test purchase on the internal track; confirm `OK` branch hit |
| Connection ready before calls | Log `onBillingSetupFinished` and confirm it precedes queries |
| Product query returns details | Log `productDetailsList.size` for a known batch |
| Unfetched handling works | Query a deliberately wrong product ID with the callback API and confirm it appears in `unfetchedProductList` with `PRODUCT_NOT_FOUND` (or `INVALID_PRODUCT_ID_FORMAT`) and is not retried |
| Disconnect recovery | Force stop the Play Store app while connected (`adb shell am force-stop com.android.vending`), confirm `onBillingServiceDisconnected()` fires, then make a billing call and confirm it succeeds without a manual `startConnection()`. Test `NETWORK_ERROR` separately in airplane mode |
| `endConnection()` on teardown | Log it in the owning scope's destroy path |

If any row fails, return to Phase 2 and revise the plan. Do not paper over a failing check.

## References

- [Full chapter](https://www.revenuecat.com/guides/google-play-billing/integrating-the-play-billing-library)

- Google Play Billing Library release notes and migration guides for version specific details.
