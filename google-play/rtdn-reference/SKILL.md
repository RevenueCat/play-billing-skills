---
name: rtdn-reference
description: Use this skill as a quick lookup for all Google Play Real Time Developer Notification (RTDN) types with their integer codes, trigger conditions, and recommended handling. Covers subscription notifications, one time purchase notifications, voided purchase notifications, pending refund review notifications, and test notifications.
license: Apache-2.0; see LICENSE
metadata:
  author: RevenueCat
  source: google-play-handbook appendix A
  keywords:
  - android
  - play-billing
  - rtdn
  - reference
  - notification-types
---

# RTDN Reference

## Phase 0: Intent

Tell the user: "I will look up the RTDN notification type you asked about and recommend handling."

## Phase 1: Locate

Map the user's question to one of the tables in Phase 2:

1. **Integer code given** (for example `notificationType: 5`): determine which notification family the user is in.
   - If the payload wraps the code in `subscriptionNotification`, use the Subscription Notification Types table.
   - If the payload wraps the code in `oneTimeProductNotification`, use the One Time Product Notification Types table.
   - If the payload has `voidedPurchaseNotification`, use the Voided Purchase Notification section.
   - If the payload has `pendingRefundReviewNotification`, use the Pending Refund Review section.
   - If the payload has `testNotification`, use the Test Notification section.
2. **Event name given** (for example `SUBSCRIPTION_ON_HOLD`): search the Type column in the Subscription or One Time Product table.
3. **Symptom given** (for example "user lost access after failed payment"): match the trigger phrase in the Trigger column. Account hold and grace period map to codes 5 and 6 respectively in the subscription table.
4. **Unassigned code** (14, 15, 16, 21): report that the code is reserved and not emitted.

After locating the row, jump to Phase 3 for the handling guidance for that family.

## Phase 2: Reference tables

### RTDN Message Structure

Every RTDN message arrives as a Cloud Pub/Sub message with a base64 encoded JSON payload in the `data` field. The decoded JSON has this structure:

```json
{
  "version": "1.0",
  "packageName": "com.example.app",
  "eventTimeMillis": "1234567890123",
  "subscriptionNotification": { },
  "oneTimeProductNotification": { },
  "voidedPurchaseNotification": { },
  "pendingRefundReviewNotification": { },
  "testNotification": { }
}
```

Only one notification field is present per message.

### Subscription Notification Types

| Code | Type | Trigger | Subscription State After | Required Action |
|------|------|---------|--------------------------|-----------------|
| 1 | `SUBSCRIPTION_RECOVERED` | Recovered from account hold, or resumed from pause (grace period recovery arrives as code 2) | `ACTIVE` | Grant access. Call `subscriptionsv2.get` to confirm state. |
| 2 | `SUBSCRIPTION_RENEWED` | Active subscription successfully renewed | `ACTIVE` | Extend entitlement. Update `expiryTime` in your database. |
| 3 | `SUBSCRIPTION_CANCELED` | Subscription canceled (user, developer, or system) | `CANCELED` | Check `canceledStateContext` for reason. User retains access until `expiryTime`. |
| 4 | `SUBSCRIPTION_PURCHASED` | New subscription purchased | `ACTIVE` | Verify purchase. Grant access. Acknowledge within 3 days. |
| 5 | `SUBSCRIPTION_ON_HOLD` | Grace period expired, entered account hold | `ON_HOLD` | Revoke access. Notify user to fix payment method. |
| 6 | `SUBSCRIPTION_IN_GRACE_PERIOD` | Renewal payment failed, entered grace period | `IN_GRACE_PERIOD` | Retain access. Notify user about payment issue. Show in app message. |
| 7 | `SUBSCRIPTION_RESTARTED` | User restored canceled subscription from Play Store before expiration | `ACTIVE` | Grant access. Same purchase token. |
| 8 | `SUBSCRIPTION_PRICE_CHANGE_CONFIRMED` | (Deprecated) User confirmed a price change | No state change | Deprecated. Use type 19 instead. |
| 9 | `SUBSCRIPTION_DEFERRED` | Subscription billing date extended via `subscriptionsv2.defer` | `ACTIVE` | Update `expiryTime` in your database. Extend access. |
| 10 | `SUBSCRIPTION_PAUSED` | Subscription paused (effective at end of current period) | `PAUSED` | Revoke access when pause begins. |
| 11 | `SUBSCRIPTION_PAUSE_SCHEDULE_CHANGED` | Pause schedule modified (pause set, changed, or removed) | Varies | Call API to check current pause schedule. |
| 12 | `SUBSCRIPTION_REVOKED` | Subscription revoked (refund, developer revocation) | `EXPIRED` | Immediately revoke access. |
| 13 | `SUBSCRIPTION_EXPIRED` | Subscription expired after cancellation or account hold failure | `EXPIRED` | Revoke access. Clean up entitlement records. |
| 17 | `SUBSCRIPTION_ITEMS_CHANGED` | Items in subscription bundle changed (add ons) | Varies | Call API to get updated line items. |
| 18 | `SUBSCRIPTION_CANCELLATION_SCHEDULED` | Installment subscription cancellation scheduled at end of commitment | `ACTIVE` (until commitment ends) | Note the scheduled cancellation. User retains access through commitment period. |
| 19 | `SUBSCRIPTION_PRICE_CHANGE_UPDATED` | Price change details updated for existing subscribers | Varies | Call API to get updated price change information. |
| 20 | `SUBSCRIPTION_PENDING_PURCHASE_CANCELED` | Pending subscription purchase was canceled | `PENDING_PURCHASE_CANCELED` | Do not grant the new purchase. If `linkedPurchaseToken` is set, the old subscription is still owned: keep its entitlement and re-read it. |
| 22 | `SUBSCRIPTION_PRICE_STEP_UP_CONSENT_UPDATED` | Price step up consent period begun or user provided consent (South Korea) | Varies | Call API to check consent status. |

Notification type codes 14, 15, 16, and 21 are not assigned. Do not expect to receive these values.

Subscription notification payload:

```json
{
  "version": "1.0",
  "notificationType": 4,
  "purchaseToken": "purchase-token-string"
}
```

### One Time Product Notification Types

| Code | Type | Trigger | Required Action |
|------|------|---------|-----------------|
| 1 | `ONE_TIME_PRODUCT_PURCHASED` | One time product purchase completed | Verify purchase. Grant access. Acknowledge or consume. |
| 2 | `ONE_TIME_PRODUCT_CANCELED` | Pending one time product purchase was canceled | Do not grant access. Clean up pending records. |

One time product notification payload:

```json
{
  "version": "1.0",
  "notificationType": 1,
  "purchaseToken": "purchase-token-string",
  "sku": "remove_ads"
}
```

One time product notifications include `sku` (the product ID). Subscription notifications carry no product ID; read `lineItems[].productId` from `purchases.subscriptionsv2.get`.

### Voided Purchase Notification

Sent when a purchase is voided due to a refund, chargeback, or revocation.

```json
{
  "purchaseToken": "purchase-token-string",
  "orderId": "GPA.1234-5678-9012-34567",
  "productType": 1,
  "refundType": 1
}
```

| Field | Values |
|-------|--------|
| `productType` | `1` = Subscription, `2` = One time product |
| `refundType` | `1` = Full refund, `2` = Quantity based refund |

### Pending Refund Review Notification

Sent for a chargeback you can respond to. Pending reviews support only `CHARGEBACK` (7) as a refund reason; handle new reasons as they become available.

```json
{
  "version": "1.0",
  "pendingRefundToken": "pending-refund-token-string",
  "orderId": "GPA.1234-5678-9012-34567",
  "refundReason": 7,
  "obfuscatedAccountId": "obfuscated-account-id-string",
  "obfuscatedProfileId": "obfuscated-profile-id-string"
}
```

### Test Notification

```json
{
  "version": "1.0"
}
```

Test notifications have only a `version` field inside the `testNotification` object.

## Phase 3: Recommended handling

### Subscription notifications

For every subscription notification:

1. Decode the base64 `data` field from the Pub/Sub message.
2. Parse the `DeveloperNotification` and read `subscriptionNotification.notificationType`.
3. Extract `purchaseToken`.
4. Call `purchases.subscriptionsv2.get` on the Google Play Developer API with the purchase token.
5. Apply the action from the Required Action column in the table, using the API response as the source of truth.
6. Acknowledge the Pub/Sub message.

Code-specific notes:

- Code `4` (purchase), including new tokens from upgrades, downgrades, resubscribes, and prepaid top ups, requires acknowledgement within 3 days (prepaid plans shorter than one week: within half the plan duration) or Google refunds it. Code `1` reuses an already acknowledged token.
- Code `3` (canceled) is not an immediate revocation. Grant access until `lineItems[].expiryTime`.
- Code `5` (on hold) is the revoke-now signal after a failed renewal. Code `6` (grace period) is the keep-access signal.
- Code `12` (revoked) requires immediate access revocation regardless of `expiryTime`.
- Codes `11`, `17`, `19`, `22` have a `Varies` state; the notification flags that something changed and the API holds the new value.
- Code `8` is deprecated. New integrations should handle code `19` instead.

### One time product notifications

1. Read `oneTimeProductNotification.notificationType` and `purchaseToken`.
2. Call `purchases.products.get` on the Google Play Developer API.
3. For code `1`, verify the purchase state, grant the entitlement, then acknowledge (non-consumable) or consume (consumable) within 3 days.
4. For code `2`, discard any pending record you created when the user began checkout.

### Voided purchase notifications

1. Revoke access immediately for the `purchaseToken`.
2. Call the Voided Purchases API (`purchases.voidedpurchases.list` with `type=1`, which also returns subscriptions; the default `type=0` returns one time purchases only) for full details, including `voidedReason` and `voidedSource`; match records by `orderId`.
3. Use `productType` to route to your subscription or one time product tables.
4. Use `refundType` to decide whether to revoke the full entitlement or only an adjusted quantity.

### Pending refund review notifications

Look up the order (`orders.get`), then call `orders.reviewrefund` (POST `applications/{packageName}/orders/{orderId}:reviewrefund`) with `pendingRefundToken`, `refundPreference`, `sampleContentProvided`, and optional consumption evidence within 24 hours.

### Test notifications

Acknowledge the Pub/Sub message without processing it as a real event. Log receipt so you can confirm your integration is wired up when you trigger a test from Play Console.

### Handler pattern (applies to every RTDN)

1. Receive the Pub/Sub message.
2. Decode the base64 `data` field.
3. Parse the JSON `DeveloperNotification`.
4. Identify which notification field is present.
5. Extract the `purchaseToken` (for a pending refund review, the `orderId` and `pendingRefundToken` instead; test notifications carry neither).
6. Call the Google Play Developer API for current state.
7. Update your database from the API response, not from the notification alone.
8. Acknowledge the Pub/Sub message.

Never rely solely on the RTDN payload for business logic. RTDNs signal that something changed. The API tells you the current state.

## References

- [Full chapter](https://www.revenuecat.com/guides/google-play-billing/appendix-complete-rtdn-reference-table)
