---
name: play-developer-api-reference
description: Use this skill as a quick reference for billing related Google Play Developer API REST endpoints, covering purchases.products, purchases.subscriptionsv2, purchases.voidedpurchases, and monetization endpoints. Lists paths, auth scopes, and typical request shapes.
license: Apache-2.0; see LICENSE
metadata:
  author: RevenueCat
  source: google-play-handbook appendix C
  keywords:
  - android
  - play-billing
  - google-play-developer-api
  - reference
  - rest-endpoints
---

# Google Play Developer API Quick Reference

## Phase 0: Intent

Use this skill when you need to look up a Google Play Developer API endpoint used for billing, subscription lifecycle management, one time product handling, refunds, voided purchase reconciliation, or catalog management. The skill returns exact REST paths, HTTP methods, response field names, query parameters, and auth scopes so you can build or debug server side calls against `androidpublisher.googleapis.com`.

Typical questions this skill answers:

- Which endpoint returns the current state of a subscription token?
- How do I cancel, revoke, or defer a subscription from the backend?
- What fields does `SubscriptionPurchaseV2` return?
- Which path consumes or acknowledges a one time product?
- How do I page through voided purchases?
- What monetization endpoints manage subscriptions, base plans, and offers?
- What quota tier applies to my call?

## Phase 1: Locate

All endpoint tables, response field schemas, and quota guidance live in the [full appendix on revenuecat.com](https://www.revenuecat.com/guides/google-play-billing/appendix-google-play-developer-api-quick-reference). Jump directly to the section that matches your use case:

| You want to... | Go to section |
|----------------|---------------|
| Inspect or mutate a subscription purchase | Subscription Purchases |
| Read fields on a subscription response | SubscriptionPurchaseV2 Response (Key Fields) |
| Inspect, acknowledge, or consume a one time product | One Time Product Purchases |
| Read fields on a product purchase response | ProductPurchase Response (Key Fields) |
| Issue a refund | Orders |
| Reconcile refunds or chargebacks | Voided Purchases |
| Query parameters for the voided purchases list | Query Parameters for Voided Purchases |
| Manage subscription products | Catalog Management: Subscriptions |
| Manage base plans | Catalog Management: Base Plans |
| Manage offers | Catalog Management: Offers |
| Manage one time products (in-app products) | Catalog Management: One Time Products |
| Understand quota tiers | Rate Limiting |

## Phase 2: Reference

Base URL for every endpoint:

```text
https://androidpublisher.googleapis.com/androidpublisher/v3/
```

### Subscription Purchases

| Endpoint | Method | Path | Description |
|----------|--------|------|-------------|
| `purchases.subscriptionsv2.get` | GET | `applications/{packageName}/purchases/subscriptionsv2/tokens/{token}` | Get the current state of a subscription. This is the source of truth. |
| `purchases.subscriptionsv2.revoke` | POST | `applications/{packageName}/purchases/subscriptionsv2/tokens/{token}:revoke` | Revoke a subscription immediately. User loses access right away. |
| `purchases.subscriptionsv2.defer` | POST | `applications/{packageName}/purchases/subscriptions/{subscriptionId}/tokens/{token}:defer` | Defer the next billing date (min 1 day, max 1 year extension). |
| `purchases.subscriptionsv2.cancel` | POST | `applications/{packageName}/purchases/subscriptions/{subscriptionId}/tokens/{token}:cancel` | Cancel a subscription. User retains access until `expiryTime`. |
| `purchases.subscriptions.get` | GET | `applications/{packageName}/purchases/subscriptions/{subscriptionId}/tokens/{token}` | Legacy endpoint. Use `subscriptionsv2.get` instead. |
| `purchases.subscriptions.acknowledge` | POST | `applications/{packageName}/purchases/subscriptions/{subscriptionId}/tokens/{token}:acknowledge` | Acknowledge a subscription purchase. |

#### SubscriptionPurchaseV2 Response (Key Fields)

| Field | Type | Description |
|-------|------|-------------|
| `kind` | string | Always `"androidpublisher#subscriptionPurchaseV2"` |
| `subscriptionState` | string | Current state: `ACTIVE`, `CANCELED`, `IN_GRACE_PERIOD`, `ON_HOLD`, `PAUSED`, `EXPIRED`, `PENDING` |
| `lineItems[]` | array | One entry per base plan/offer in the subscription |
| `lineItems[].productId` | string | The subscription product ID |
| `lineItems[].expiryTime` | timestamp | When this line item expires |
| `lineItems[].autoRenewingPlan` | object | Present for auto renewing plans. Contains `autoRenewEnabled`. |
| `lineItems[].prepaidPlan` | object | Present for prepaid plans. Contains `allowExtendAfterTime`. |
| `lineItems[].offerDetails` | object | Offer applied to this line item. Contains `offerTags[]`, `basePlanId`. |
| `linkedPurchaseToken` | string | If this purchase replaces another, the token of the replaced purchase. |
| `startTime` | timestamp | When the subscription was first purchased. |
| `regionCode` | string | ISO 3166-1 alpha-2 country code of the user. |
| `canceledStateContext` | object | Why the subscription was canceled. Contains `userInitiatedCancellation`, `systemInitiatedCancellation`, or `developerInitiatedCancellation`. |
| `acknowledgementState` | string | `ACKNOWLEDGEMENT_STATE_PENDING` or `ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED` |
| `externalAccountIdentifiers` | object | Contains `obfuscatedExternalAccountId` and `obfuscatedExternalProfileId`. |
| `pausedStateContext` | object | Present when paused. Contains `autoResumeTime`. |

### One Time Product Purchases

| Endpoint | Method | Path | Description |
|----------|--------|------|-------------|
| `purchases.products.get` | GET | `applications/{packageName}/purchases/products/{productId}/tokens/{token}` | Get the state of a one time product purchase. |
| `purchases.productsv2.getproductpurchasev2` | GET | `applications/{packageName}/purchases/productsv2/tokens/{token}` | Get one time product purchase using v2 API (no productId required). |
| `purchases.products.acknowledge` | POST | `applications/{packageName}/purchases/products/{productId}/tokens/{token}:acknowledge` | Acknowledge a one time product purchase. |
| `purchases.products.consume` | POST | `applications/{packageName}/purchases/products/{productId}/tokens/{token}:consume` | Consume a one time product (makes it available for repurchase). |

#### ProductPurchase Response (Key Fields)

| Field | Type | Description |
|-------|------|-------------|
| `kind` | string | Always `"androidpublisher#productPurchase"` |
| `purchaseTimeMillis` | long | Time of purchase in milliseconds since epoch. |
| `purchaseState` | integer | `0` = Purchased, `1` = Canceled, `2` = Pending |
| `consumptionState` | integer | `0` = Not consumed, `1` = Consumed |
| `orderId` | string | The order ID for this transaction. |
| `acknowledgementState` | integer | `0` = Not acknowledged, `1` = Acknowledged |
| `purchaseToken` | string | The purchase token. |
| `productId` | string | The product ID. |
| `quantity` | integer | Quantity purchased (for multi quantity purchases). |
| `obfuscatedExternalAccountId` | string | Obfuscated account ID set during purchase. |
| `obfuscatedExternalProfileId` | string | Obfuscated profile ID set during purchase. |
| `regionCode` | string | ISO 3166-1 alpha-2 country code. |

### Orders

| Endpoint | Method | Path | Description |
|----------|--------|------|-------------|
| `orders.refund` | POST | `applications/{packageName}/orders/{orderId}:refund` | Issue a full refund. Available within 3 years of purchase. |

### Voided Purchases

| Endpoint | Method | Path | Description |
|----------|--------|------|-------------|
| `purchases.voidedpurchases.list` | GET | `applications/{packageName}/purchases/voidedpurchases` | List voided (refunded/revoked) purchases. Supports pagination and filtering by time. |

#### Query Parameters for Voided Purchases

| Parameter | Type | Description |
|-----------|------|-------------|
| `startTime` | long | Milliseconds since epoch. Only return purchases voided after this time. |
| `endTime` | long | Milliseconds since epoch. Only return purchases voided before this time. |
| `startIndex` | integer | Pagination offset. |
| `maxResults` | integer | Maximum results per page (default 1000, max 1000). |
| `type` | integer | `0` = Both, `1` = Subscriptions only, `2` = One time products only |
| `includeQuantityBasedPartialRefund` | boolean | Include partial quantity based refunds. |

### Catalog Management: Subscriptions

| Endpoint | Method | Path | Description |
|----------|--------|------|-------------|
| `monetization.subscriptions.create` | POST | `applications/{packageName}/subscriptions` | Create a new subscription. |
| `monetization.subscriptions.get` | GET | `applications/{packageName}/subscriptions/{productId}` | Get subscription details. |
| `monetization.subscriptions.list` | GET | `applications/{packageName}/subscriptions` | List all subscriptions. |
| `monetization.subscriptions.patch` | PATCH | `applications/{packageName}/subscriptions/{productId}` | Update subscription fields. |
| `monetization.subscriptions.delete` | DELETE | `applications/{packageName}/subscriptions/{productId}` | Delete a draft subscription. |
| `monetization.subscriptions.batchGet` | GET | `applications/{packageName}/subscriptions:batchGet` | Get multiple subscriptions (up to 100). |
| `monetization.subscriptions.batchUpdate` | POST | `applications/{packageName}/subscriptions:batchUpdate` | Update multiple subscriptions (up to 100). |

### Catalog Management: Base Plans

| Endpoint | Method | Path | Description |
|----------|--------|------|-------------|
| `monetization.subscriptions.basePlans.activate` | POST | `...basePlans/{basePlanId}:activate` | Activate a base plan. |
| `monetization.subscriptions.basePlans.deactivate` | POST | `...basePlans/{basePlanId}:deactivate` | Deactivate a base plan. |
| `monetization.subscriptions.basePlans.delete` | DELETE | `...basePlans/{basePlanId}` | Delete a base plan. |
| `monetization.subscriptions.basePlans.migratePrices` | POST | `...basePlans/{basePlanId}:migratePrices` | End a legacy price cohort by migrating subscribers to the current price. |
| `monetization.subscriptions.basePlans.batchMigratePrices` | POST | `...basePlans:batchMigratePrices` | Batch price migration. |
| `monetization.subscriptions.basePlans.batchUpdateStates` | POST | `...basePlans:batchUpdateStates` | Batch activate/deactivate. |

### Catalog Management: Offers

| Endpoint | Method | Path | Description |
|----------|--------|------|-------------|
| `monetization.subscriptions.basePlans.offers.create` | POST | `...offers` | Create an offer. |
| `monetization.subscriptions.basePlans.offers.get` | GET | `...offers/{offerId}` | Get offer details. |
| `monetization.subscriptions.basePlans.offers.list` | GET | `...offers` | List offers for a base plan. |
| `monetization.subscriptions.basePlans.offers.patch` | PATCH | `...offers/{offerId}` | Update an offer. |
| `monetization.subscriptions.basePlans.offers.delete` | DELETE | `...offers/{offerId}` | Delete a draft offer. |
| `monetization.subscriptions.basePlans.offers.activate` | POST | `...offers/{offerId}:activate` | Activate an offer. |
| `monetization.subscriptions.basePlans.offers.deactivate` | POST | `...offers/{offerId}:deactivate` | Deactivate an offer. |
| `monetization.subscriptions.basePlans.offers.batchGet` | GET | `...offers:batchGet` | Get multiple offers. |
| `monetization.subscriptions.basePlans.offers.batchUpdate` | POST | `...offers:batchUpdate` | Update multiple offers. |
| `monetization.subscriptions.basePlans.offers.batchUpdateStates` | POST | `...offers:batchUpdateStates` | Batch activate/deactivate offers. |

### Catalog Management: One Time Products (In-App Products)

| Endpoint | Method | Path | Description |
|----------|--------|------|-------------|
| `inappproducts.insert` | POST | `applications/{packageName}/inappproducts` | Create a one time product. |
| `inappproducts.get` | GET | `applications/{packageName}/inappproducts/{sku}` | Get product details. |
| `inappproducts.list` | GET | `applications/{packageName}/inappproducts` | List all one time products. |
| `inappproducts.patch` | PATCH | `applications/{packageName}/inappproducts/{sku}` | Update product fields. |
| `inappproducts.update` | PUT | `applications/{packageName}/inappproducts/{sku}` | Replace product entirely. |
| `inappproducts.delete` | DELETE | `applications/{packageName}/inappproducts/{sku}` | Delete a product. |
| `inappproducts.batchGet` | GET | `applications/{packageName}/inappproducts:batchGet` | Get multiple products (up to 100). |
| `inappproducts.batchUpdate` | POST | `applications/{packageName}/inappproducts:batchUpdate` | Update multiple products (up to 100). |
| `inappproducts.batchDelete` | POST | `applications/{packageName}/inappproducts:batchDelete` | Delete multiple products. |

### Rate Limiting

| Tier | Default Quota | Endpoints |
|------|---------------|-----------|
| Read | Higher limits | All `get`, `list`, `batchGet` operations |
| Write | Lower limits | All `create`, `update`, `patch`, `delete`, `batchUpdate` operations |
| Sensitive | Most restricted | `refund`, `revoke`, price migration operations |

Quota is measured per project, per minute. When you exceed your quota, the API returns HTTP 429 (Too Many Requests). Implement exponential backoff for quota errors. You can monitor usage in the Google Cloud Console under **APIs & Services > Dashboard > Android Publisher API**.

## Phase 3: Auth and Scopes

Every call to `androidpublisher.googleapis.com` uses OAuth 2.0. The only scope you need for billing operations is:

```text
https://www.googleapis.com/auth/androidpublisher
```

Guidance for a server side integration:

1. Create a service account in the Google Cloud project linked to your Play Console.
2. Grant the service account access in Play Console under **Users and permissions**. Assign only the permissions you need. For subscription reads assign "View financial data, orders, and cancellation survey responses". For mutations assign "Manage orders and subscriptions".
3. Mint a short lived access token from the service account JSON key using your platform's Google auth client. Cache the token until a minute before expiry.
4. Send `Authorization: Bearer <token>` on every request. Set `Content-Type: application/json` for POST, PATCH, and PUT bodies.
5. Use exponential backoff for HTTP 429 and 5xx responses. Treat 401 as "refresh token" and 403 as "fix permissions", not as retry candidates.

Typical request shape for a subscription state lookup:

```http
GET /androidpublisher/v3/applications/com.example.app/purchases/subscriptionsv2/tokens/abc123 HTTP/1.1
Host: androidpublisher.googleapis.com
Authorization: Bearer ya29.a0Af...
Accept: application/json
```

Typical request shape for a cancel call:

```http
POST /androidpublisher/v3/applications/com.example.app/purchases/subscriptions/premium_monthly/tokens/abc123:cancel HTTP/1.1
Host: androidpublisher.googleapis.com
Authorization: Bearer ya29.a0Af...
Content-Length: 0
```

Typical request shape for a voided purchases page:

```http
GET /androidpublisher/v3/applications/com.example.app/purchases/voidedpurchases?startTime=1704067200000&maxResults=1000&type=0 HTTP/1.1
Host: androidpublisher.googleapis.com
Authorization: Bearer ya29.a0Af...
```

## References

- [Full chapter](https://www.revenuecat.com/guides/google-play-billing/appendix-google-play-developer-api-quick-reference)

- Google Play Developer API docs: https://developers.google.com/android-publisher
- OAuth scope registry: https://developers.google.com/identity/protocols/oauth2/scopes#androidpublisher
