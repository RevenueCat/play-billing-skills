---
name: security
description: Use this skill when hardening a Google Play Billing integration against fraud. Covers server side receipt verification, replay attack protection, device fingerprinting, velocity checks, and the most common billing fraud patterns.
license: Apache-2.0; see LICENSE
metadata:
  author: RevenueCat
  source: google-play-handbook chapter 15
  keywords:
  - android
  - play-billing
  - security
  - fraud
  - receipt-verification
  - replay-attack
---

# Securing Google Play Billing

Anything running on the user device can be tampered with. If your trust model lives in the client, you have already lost. This skill shows you how to move trust to your backend and defend against the attack patterns you will actually see in production.

## Phase 1: Assess

Before you write a line of defensive code, answer these questions about your current integration:

- Where does purchase verification happen today? Client, backend, or both?
- Does your database enforce a unique constraint on `purchaseToken`?
- Do you set `obfuscatedAccountId` and `obfuscatedProfileId` on every purchase flow?
- Do you poll the Voided Purchases API on a schedule?
- Do any access decisions rely on `System.currentTimeMillis()` from the device?

Any "no" answer maps to a layer you are missing below.

## Phase 2: Plan the Layered Defense

Fraud prevention is not a single check. It is a stack of controls where each layer catches a different attack class. Plan all of them, even if you ship them incrementally.

| Layer | Purpose | Where it runs |
|---|---|---|
| 1. Backend receipt verification | Confirm the purchase exists in Google's records | Your server, via `purchases.products.get` / `purchases.subscriptionsv2.get` |
| 2. Response field validation | Catch product swaps and cross app token reuse | Your server (check `packageName`, `productId`, `orderId`) |
| 3. Purchase state check | Reject `PENDING` and expired purchases | Your server |
| 4. Replay protection | Block reuse of valid tokens | Unique constraint on purchase token column |
| 5. Token to user binding | Detect token sharing across accounts | Your server (store and compare userId on duplicates) |
| 6. Acknowledgement | Prevent auto refund at 3 day mark | Your server, after entitlement grant |
| 7. Voided purchase sync | Revoke access on refunds and chargebacks | Daily batch job against `purchases.voidedpurchases.list` |
| 8. Device and profile signals | Give Google and yourself correlation data | Client sets `obfuscatedAccountId` / `obfuscatedProfileId` before launching the flow |
| 9. Integrity and pinning | Raise the cost of modified APKs | Play Integrity API plus TLS certificate pinning |
| 10. Server time of record | Defeat timezone manipulation | All time decisions use server clock |

Decide the order based on risk. For most apps: layers 1 through 6 are non negotiable for launch. Layer 7 follows within the first week. Layers 8 through 10 harden against the targeted attacks you will see later.

## Phase 3: Execute

### Step 1: Send the token from client to backend

Keep the client thin. Its only job is to hand the token to your server along with the current user identifier.

```kotlin
override fun onPurchasesUpdated(
    result: BillingResult,
    purchases: List<Purchase>?
) {
    if (result.responseCode != BillingResponseCode.OK) return
    purchases?.forEach { p ->
        if (p.purchaseState == PurchaseState.PURCHASED) {
            api.verify(p.purchaseToken, p.products, currentUserId)
        }
    }
}
```

Send over HTTPS. Pin the server certificate if you can. Include your own auth token so the server knows which user is claiming the purchase.

### Step 2: Verify on the backend and bind the token to the user

The server is the only place that decides whether a purchase is real. Call the Google Play Developer API, validate the response, then atomically insert the entitlement under a unique constraint on `purchase_token`. That constraint is your replay defense.

```python
def grant_entitlement(token, claimed_product, user_id):
    record = play_api.get_purchase(PACKAGE, claimed_product, token)
    assert record["packageName"] == PACKAGE
    assert record["productId"] == claimed_product
    assert record["purchaseState"] == 0  # PURCHASED, not PENDING
    existing = db.entitlements.find_by_token(token)
    if existing:
        if existing.user_id != user_id:
            security_log.flag("token_reuse", token, user_id)
        return existing
    db.entitlements.insert_unique(token, user_id, record["orderId"])
    play_api.acknowledge(PACKAGE, claimed_product, token)
```

Two things do the real work here. First, the unique insert on `token` means a replayed token from any account is a database conflict, not a second grant. Second, comparing the claiming `user_id` against the original owner on every lookup surfaces token sharing and account abuse patterns that a naive "already processed, return success" path would hide.

### Step 3: Add device and profile signals before the purchase

Set both obfuscated identifiers on every purchase flow. They cost nothing and give Google, and you, a way to correlate across sessions and Google accounts.

```kotlin
val params = BillingFlowParams.newBuilder()
    .setProductDetailsParamsList(listOf(productParams))
    .setObfuscatedAccountId(sha256(currentUser.id))
    .setObfuscatedProfileId(sha256(currentUser.activeProfileId))
    .build()
billingClient.launchBillingFlow(activity, params)
```

Both values come back in the purchase record, so your backend can reconcile them with your user database even if the user switches Google accounts.

## Fraud Pattern to Mitigation Reference

| Fraud pattern | Primary mitigation | Backstop |
|---|---|---|
| Modified APK removes client checks | Backend receipt verification | Play Integrity API, R8 obfuscation |
| Fabricated purchase tokens | `purchases.products.get` returns error, server rejects | Package name and product ID checks |
| Stolen token from another app | `packageName` validation on the API response | Order ID uniqueness |
| Product swap (cheap token, expensive claim) | `productId` validation against client claim | Price recorded from API response, not client |
| Replayed token on same account | Unique constraint on `purchase_token` | Idempotent grant returns existing record |
| Replayed token across accounts | Token to user binding with alert on mismatch | Device fingerprint correlation |
| Pending payment treated as paid | Reject `purchaseState == 2`, wait for RTDN | Acknowledge only after state becomes PURCHASED |
| Missed acknowledgement triggers auto refund | Server side acknowledge after grant with retry | Monitor acknowledgement failures as high priority |
| Refund abuse and chargebacks | Daily `purchases.voidedpurchases.list` poll | Graduated enforcement (warn, restrict, ban) |
| Consumable refund after spend | Deduct refunded amount from user balance | Restrict access until balance is non negative |
| Account sharing across many devices | Concurrent device limit, device fingerprinting | Flag high distinct device count per token |
| Timezone and clock manipulation | Server clock is the only clock for access decisions | `SystemClock.elapsedRealtime()` for offline grace |
| Ban evasion via new account | Store device and account identifiers of banned users | Apply restrictions on first matching signal |

## Common Pitfalls

- Acknowledging from the client. If the client acknowledges before your server grants entitlement, a failure leaves the user charged with no access. Acknowledge on the server, after the grant.
- Returning 200 on duplicate tokens without checking the original owner. You miss token sharing entirely.
- Bundling premium assets in `assets/` or `res/`. Any APK extractor pulls them out. Host premium content on your server and gate downloads on verified entitlement.
- Real time revocation when a void is detected. Batch revocations during your regular sync. Google occasionally reverses voids.
- Using `System.currentTimeMillis()` for trial eligibility or offer windows. The device clock is user controlled.

## References

- [Full chapter](https://www.revenuecat.com/guides/google-play-billing/security-and-fraud-prevention)
