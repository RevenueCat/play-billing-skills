---
name: subscription-state-diagram
description: Use this skill as the pull out reference for the full Google Play subscription state machine, showing every state and every RTDN triggered transition in one diagram.
license: Apache-2.0; see LICENSE
metadata:
  author: RevenueCat
  source: google-play-handbook appendix E
  keywords:
  - android
  - play-billing
  - subscriptions
  - state-diagram
  - reference
---

# Subscription State Diagram

## Phase 0: Intent

Use this skill when you need a single place to look up:

- What states a Google Play subscription can be in.
- Which RTDN (Real Time Developer Notification) moves a subscription from one state to the next.
- Whether a given state grants access to paid content.
- What token behavior to expect across renewals, pauses, holds, and resubscribes.

This is a reference skill. It does not write code for you. It hands you the map so you can point at a node, point at an edge, and then make a decision about access or acknowledgement.

## Phase 1: Locate

Tell the skill which part of the state machine you care about. Pick the shortest path that matches your question.

| You want to know... | Jump to |
|---------------------|---------|
| What every state means and whether it grants access | States at a Glance |
| Which RTDN fires on a specific transition | Transition Table |
| Whether to grant access right now | Access Decision Flowchart |
| What happens to the purchase token across events | Token Lifecycle |
| The numeric code for a notification type | RTDN Quick Reference |
| How long grace period, account hold, or token validity lasts | Time Windows |

A typical lookup looks like this:

1. Name the current state (for example `IN_GRACE_PERIOD`).
2. Name the event you observed (for example RTDN type 5).
3. Find the row in the From `IN_GRACE_PERIOD` table.
4. Read the target state and the access rule.

## Phase 2: Reference Diagram

### States at a Glance

| State | Access | Description |
|-------|--------|-------------|
| PENDING | No | Purchase initiated, payment not yet processed |
| ACTIVE | Yes | Subscription is paid and current |
| IN_GRACE_PERIOD | Yes | Payment failed, Google is retrying, user keeps access |
| ON_HOLD | No | Grace period expired, access revoked, awaiting payment fix |
| PAUSED | No | User requested pause, access revoked |
| CANCELED | Until expiry | Canceled but not expired, access until `expiryTime` |
| EXPIRED | No | Subscription has ended |

### Transition Table

Every edge in the diagram. Columns: origin state, destination state, trigger, RTDN name and numeric type.

| From | To | Trigger | RTDN |
|------|----|---------|------|
| PENDING | ACTIVE | Payment completes | `SUBSCRIPTION_PURCHASED` (4) |
| PENDING | EXPIRED | Payment fails or times out | `SUBSCRIPTION_PENDING_PURCHASE_CANCELED` (20) |
| ACTIVE | ACTIVE | Successful renewal | `SUBSCRIPTION_RENEWED` (2) |
| ACTIVE | IN_GRACE_PERIOD | Renewal fails, grace period enabled | `SUBSCRIPTION_IN_GRACE_PERIOD` (6) |
| ACTIVE | ON_HOLD | Renewal fails, no grace, account hold enabled | `SUBSCRIPTION_ON_HOLD` (5) |
| ACTIVE | CANCELED | User or developer cancels | `SUBSCRIPTION_CANCELED` (3) |
| ACTIVE | EXPIRED | Revoked or refunded | `SUBSCRIPTION_REVOKED` (12) |
| ACTIVE | PAUSED | Pause takes effect at end of period | `SUBSCRIPTION_PAUSED` (10) |
| IN_GRACE_PERIOD | ACTIVE | Payment recovered | `SUBSCRIPTION_RECOVERED` (1) |
| IN_GRACE_PERIOD | ON_HOLD | Grace expires without payment | `SUBSCRIPTION_ON_HOLD` (5) |
| IN_GRACE_PERIOD | EXPIRED | Grace expires, no account hold | `SUBSCRIPTION_EXPIRED` (13) |
| ON_HOLD | ACTIVE | User fixes payment | `SUBSCRIPTION_RECOVERED` (1) |
| ON_HOLD | EXPIRED | Account hold period expires | `SUBSCRIPTION_EXPIRED` (13) |
| PAUSED | ACTIVE | Pause ends, payment succeeds | `SUBSCRIPTION_RECOVERED` (1) |
| PAUSED | ON_HOLD | Pause ends, payment fails | `SUBSCRIPTION_ON_HOLD` (5) |
| CANCELED | ACTIVE | User restores before expiration | `SUBSCRIPTION_RESTARTED` (7) |
| CANCELED | EXPIRED | `expiryTime` reached | `SUBSCRIPTION_EXPIRED` (13) |
| EXPIRED | ACTIVE | User resubscribes, new purchase token | `SUBSCRIPTION_PURCHASED` (4) |

### RTDN Quick Reference by Number

| # | Name | Common Usage |
|---|------|--------------|
| 1 | RECOVERED | Restore access after hold or pause |
| 2 | RENEWED | Extend access period |
| 3 | CANCELED | Note cancellation, keep access until expiry |
| 4 | PURCHASED | New subscription, grant access |
| 5 | ON_HOLD | Revoke access |
| 6 | IN_GRACE_PERIOD | Keep access, warn user |
| 7 | RESTARTED | Restore access, same token |
| 8 | PRICE_CHANGE_CONFIRMED | Deprecated |
| 9 | DEFERRED | Extend billing date |
| 10 | PAUSED | Revoke access at period end |
| 11 | PAUSE_SCHEDULE_CHANGED | Check pause status |
| 12 | REVOKED | Immediately revoke access |
| 13 | EXPIRED | Revoke access, clean up |
| 17 | ITEMS_CHANGED | Check updated line items |
| 18 | CANCELLATION_SCHEDULED | Note scheduled cancellation |
| 19 | PRICE_CHANGE_UPDATED | Check price change details |
| 20 | PENDING_PURCHASE_CANCELED | Clean up pending records |
| 22 | PRICE_STEP_UP_CONSENT_UPDATED | Check consent status |

### Time Windows

| Window | Duration | What Happens |
|--------|----------|--------------|
| Acknowledgement | 3 days | Unacknowledged purchases auto refund |
| Grace period | 1 to 30 days, configurable | User keeps access while Google retries |
| Silent grace period | 1 day minimum | Applies even when grace is set to 0 days |
| Account hold | Up to 30 days, configurable | User loses access, can recover by fixing payment |
| Token validity | 60 days post expiration | API calls still succeed in this window |
| Pause duration | 1 week to 3 months | Depends on billing period |

## Phase 3: Handling Guidance Per Transition

Each row tells you what to do when the RTDN lands. Pair this with the access rule in Phase 2.

| Transition | Your handler should |
|------------|----------------------|
| PENDING to ACTIVE | Acknowledge within 3 days, provision entitlement, store the purchase token |
| PENDING to EXPIRED | Clean up the pending record, do not provision access |
| ACTIVE to ACTIVE (renewal) | Extend the entitlement to the new `expiryTime`, keep the same token |
| ACTIVE to IN_GRACE_PERIOD | Keep access on, surface a payment warning, trigger In App Messaging |
| ACTIVE to ON_HOLD | Revoke access, tell the user to fix payment in Play |
| ACTIVE to CANCELED | Keep access until `expiryTime`, show an expiry countdown, log the cancel reason |
| ACTIVE to EXPIRED (revoke) | Revoke access immediately, note the refund or revocation |
| ACTIVE to PAUSED | Access ends at period end, show resume date on next open |
| IN_GRACE_PERIOD to ACTIVE | Clear the warning banner, confirm `expiryTime` moved forward |
| IN_GRACE_PERIOD to ON_HOLD | Revoke access, swap the warning for a fix payment prompt |
| IN_GRACE_PERIOD to EXPIRED | Revoke access, offer resubscribe |
| ON_HOLD to ACTIVE | Restore the entitlement, keep the existing token |
| ON_HOLD to EXPIRED | Revoke, offer resubscribe, stop polling the token after 60 days |
| PAUSED to ACTIVE | Restore access, same token |
| PAUSED to ON_HOLD | Keep access revoked, switch message to fix payment |
| CANCELED to ACTIVE | Restore, same token, remove the expiry countdown |
| CANCELED to EXPIRED | Revoke, offer resubscribe |
| EXPIRED to ACTIVE | Treat as a new purchase, new token, link it to the prior user identity |

### Access Decision

Use the same rule across every handler.

```kotlin
fun shouldGrantAccess(
    state: String,
    expiryTimeMillis: Long
): Boolean = when (state) {
    "SUBSCRIPTION_STATE_ACTIVE",
    "SUBSCRIPTION_STATE_IN_GRACE_PERIOD" -> true
    "SUBSCRIPTION_STATE_CANCELED" ->
        System.currentTimeMillis() < expiryTimeMillis
    else -> false
}
```

### Token Lifecycle

| Event | Token Behavior |
|-------|----------------|
| New purchase | New token |
| Renewal | Same token, new Order ID |
| Upgrade or downgrade | New token, old token linked via `linkedPurchaseToken` |
| Restore before expiry | Same token |
| Resubscribe after expiry | New token |
| Pause and resume | Same token |
| Grace period recovery | Same token |
| Account hold recovery | Same token |

## References

- [Full chapter](https://www.revenuecat.com/guides/google-play-billing/appendix-subscription-state-diagram)
