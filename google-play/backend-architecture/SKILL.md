---
name: backend-architecture
description: Use this skill when building a backend for Google Play Billing receipt verification. Covers receiving purchase tokens from the client, calling the Google Play Developer API to verify, storing subscription state, and exposing a production ready verification endpoint.
license: Apache-2.0; see LICENSE
metadata:
  author: RevenueCat
  source: google-play-handbook chapter 9
  keywords:
  - android
  - play-billing
  - backend
  - receipt-verification
  - google-play-developer-api
  - service-account
---

# Backend Architecture for Play Billing

The client is not trustworthy. Signatures can be forged, APKs can be modified, and local purchase data can be faked. Your backend must treat the purchase token as an opaque value to verify with Google. This skill walks you through the verification pipeline, from receiving a token to persisting entitlement state.

## Phase 1: Scope

Confirm the following before you write code.

- You know which product types you sell (subscriptions, consumables, non consumables). The API endpoint differs per type.
- You have a user identity model. Each purchase token must map to one user account on your server.
- You have (or can add) a database for purchase records. The schema uses `purchaseToken` as the primary key.
- You have a plan for acknowledgement within 3 days. Unacknowledged purchases auto refund.
- You have a Google Play Console account and can access **Setup > API access**.

If any of these are missing, stop and resolve before continuing.

## Phase 2: Plan

### 2.1 Configure Google Play Developer API access

Do these steps once per project.

1. In Play Console, open **Setup > API access** and link a Google Cloud project.
2. In Cloud Console, enable the **Google Play Android Developer API**.
3. Create a service account (for example `play-billing-backend`). No Cloud IAM roles are required.
4. Generate a JSON key from the service account and store it as a secret. Never commit it.
5. Back in Play Console, grant the service account **Financial data** and **Manage orders** permissions on your app.

For containerized deployments on Google Cloud, prefer Workload Identity Federation over JSON key files. `GoogleCredentials.getApplicationDefault()` picks up the attached service account automatically.

### 2.2 Map the seven step verification flow

Every purchase follows the same pipeline. Plan each step in code before wiring them.

1. Receive purchase token from client.
2. Call Google Play Developer API to fetch purchase state.
3. Validate response fields (product ID, package name).
4. Check purchase state is active or purchased.
5. Check the token is not already processed (idempotency).
6. Persist record and grant entitlement.
7. Acknowledge the purchase with Google.

### 2.3 Pick your database key

Use `purchaseToken` as the primary key for purchase records.

| Identifier | Use it as key? | Reason |
| --- | --- | --- |
| `purchaseToken` | Yes | What the Developer API accepts. Stable across subscription renewals. |
| `orderId` | No (store only) | Changes every renewal (appended `..0`, `..1`). Useful for support and reconciliation. |
| `linkedPurchaseToken` | No (foreign key) | Points to the previous token in an upgrade or downgrade chain. |

## Phase 3: Execute

### 3.1 Build the authenticated Play Publisher client

Initialize once at startup. The client is thread safe and caches access tokens internally.

```kotlin
fun createPublisherClient(): AndroidPublisher {
    val credentials = GoogleCredentials
        .getApplicationDefault()
        .createScoped(listOf(AndroidPublisherScopes.ANDROIDPUBLISHER))
    val transport = GoogleNetHttpTransport.newTrustedTransport()
    return AndroidPublisher.Builder(
        transport,
        GsonFactory.getDefaultInstance(),
        HttpCredentialsAdapter(credentials),
    ).setApplicationName("your-app-backend").build()
}
```

### 3.2 Expose the verification endpoint

The client posts the purchase token, product ID, and user ID. Your endpoint runs the full pipeline and returns a final entitlement decision.

```kotlin
@PostMapping("/purchases/verify")
fun verify(@RequestBody req: VerifyRequest): VerifyResponse {
    val sub = publisher.purchases().subscriptionsv2()
        .get(packageName, req.purchaseToken).execute()
    validateOrThrow(sub, req.productId)
    requireActive(sub.subscriptionState)
    return processPurchase(req.userId, req.purchaseToken, sub)
}
```

### 3.3 Call the Developer API for subscriptions

`purchases.subscriptionsv2.get` is the source of truth for subscription state.

```kotlin
fun getSubscription(packageName: String, token: String): SubscriptionPurchaseV2 =
    publisher.purchases().subscriptionsv2().get(packageName, token).execute()
```

Fields to read from the response:

| Field | Purpose |
| --- | --- |
| `subscriptionState` | Active, canceled, in grace period, on hold, paused, expired, or pending. |
| `lineItems[].productId` | Product sold. Must match what the client claimed. |
| `lineItems[].expiryTime` | Current period end. |
| `linkedPurchaseToken` | Previous token in upgrade or downgrade chain. |
| `acknowledgementState` | Whether you have acknowledged yet. |
| `externalAccountIdentifiers` | Obfuscated account and profile IDs from the purchase flow. |

Grant the entitlement only when `subscriptionState == SUBSCRIPTION_STATE_ACTIVE`.

### 3.4 Call the Developer API for one time products

`purchases.products.get` requires the product ID in the path.

```kotlin
fun getProduct(packageName: String, productId: String, token: String): ProductPurchase =
    publisher.purchases().products().get(packageName, productId, token).execute()
```

| Field | Meaning |
| --- | --- |
| `purchaseState` | 0 purchased, 1 canceled, 2 pending. Grant only on 0. |
| `consumptionState` | 0 not consumed, 1 consumed. |
| `acknowledgementState` | 0 not acknowledged, 1 acknowledged. |
| `orderId` | Store for support and reconciliation. |

### 3.5 Persist the record with idempotency

Use the purchase token as the primary key. Check for duplicates before granting.

```kotlin
data class PurchaseRecord(
    val purchaseToken: String,
    val userId: String,
    val productId: String,
    val orderId: String?,
    val purchaseState: String,
    val linkedPurchaseToken: String?,
    val acknowledgedAt: Instant?,
    val grantedAt: Instant,
)
```

```kotlin
fun processPurchase(userId: String, token: String, sub: SubscriptionPurchaseV2) {
    sub.linkedPurchaseToken?.let { purchaseRepository.deactivate(it) }
    if (purchaseRepository.findByToken(token) != null) return
    purchaseRepository.save(recordFrom(userId, token, sub))
    entitlementService.activate(userId, sub.lineItems.first().productId)
}
```

Deactivating the linked token prevents two active entitlements after an upgrade or downgrade.

### 3.6 Acknowledge within 3 days

Acknowledge from the backend after the entitlement is granted. If acknowledgement fails, retry with backoff.

```kotlin
fun acknowledgeSubscription(packageName: String, productId: String, token: String) {
    publisher.purchases().subscriptions()
        .acknowledge(packageName, productId, token, SubscriptionPurchasesAcknowledgeRequest())
        .execute()
}
```

For one time products, pick the call that matches the product type.

| Product type | API call | Notes |
| --- | --- | --- |
| Non consumable | `purchases.products.acknowledge` | Grants permanent ownership. |
| Consumable | `purchases.products.consume` | Also acknowledges. Do not call both. |
| Subscription | `purchases.subscriptions.acknowledge` | Renewals are already acknowledged. |

### 3.7 Retry transient errors

Back off on 429 and 503. Respect `Retry-After` when present.

```kotlin
fun <T> executeWithRetry(maxAttempts: Int = 3, block: () -> T): T {
    repeat(maxAttempts) { attempt ->
        try { return block() } catch (e: GoogleJsonResponseException) {
            if (e.statusCode !in listOf(429, 503)) throw e
            Thread.sleep((1L shl attempt) * 1000L)
        }
    }
    throw RuntimeException("Retries exhausted")
}
```

### 3.8 Stay inside your quota

The default quota is 200,000 queries per day across `subscriptionsv2.get` and `products.get`. Apply all four practices.

- Cache verification results for 5 to 15 minutes keyed by token.
- Use Real Time Developer Notifications through Pub Sub for state changes instead of polling.
- Serve entitlement checks from your database. Do not call Google on every app launch.
- Monitor quota in Cloud Console and alert at 80 percent.

## Phase 4: Verify

Before you call the backend done, confirm:

- A purchase token posted twice results in exactly one entitlement grant (idempotency).
- An upgrade produces a new token whose `linkedPurchaseToken` deactivates the old entitlement.
- A pending purchase with `purchaseState == 2` is stored but not granted until it transitions to 0.
- Acknowledgement happens after the grant and within 3 days. Simulate a missed acknowledgement and confirm the auto refund.
- A resubscription after cancellation is linked to the user through `externalAccountIdentifiers`, not through a token chain, because Google does not always set `linkedPurchaseToken` on resubscribe.
- The service account JSON key is not in git, not in logs, and rotates on a schedule.
- Load tests do not push your daily quota above 80 percent.

## References

- [Full chapter](https://www.revenuecat.com/guides/google-play-billing/backend-architecture-for-billing)
