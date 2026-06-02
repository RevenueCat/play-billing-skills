---
name: payment-recovery
description: Use this skill when handling failed subscription renewals on Google Play. Covers Grace Period (user keeps access), Account Hold (access revoked), the RTDN signals that move between stages, and the in app messaging required to drive recovery.
license: Apache-2.0; see LICENSE
metadata:
  author: RevenueCat
  source: google-play-handbook chapter 12
  keywords:
  - android
  - play-billing
  - payment-recovery
  - grace-period
  - account-hold
  - dunning
---

# Payment Recovery: Grace Period and Account Hold

Google Play does not cancel a subscription the moment a renewal charge fails. It runs a two stage recovery process: grace period (user keeps access while Google retries) then account hold (access revoked while Google keeps retrying). Your job is to react to the right RTDNs, toggle entitlements at the right moments, and prompt the user to fix payment without forcing them to leave your app.

## Phase 1: Understand

Map the stages, the RTDN for each transition, and the entitlement you should hold.

| Stage | Entry RTDN | Duration | User access | `SubscriptionPurchaseV2` state |
|---|---|---|---|---|
| Silent grace period | none (always applies) | ~1 day | Active | `SUBSCRIPTION_STATE_ACTIVE` |
| Configured grace period | `SUBSCRIPTION_IN_GRACE_PERIOD` | 0 to 30 days (per base plan) | Keep full access | `SUBSCRIPTION_STATE_IN_GRACE_PERIOD` |
| Account hold | `SUBSCRIPTION_ON_HOLD` | 0 to 30 days | Revoke | `SUBSCRIPTION_STATE_ON_HOLD` |
| Recovered | `SUBSCRIPTION_RECOVERED` | n/a | Restore immediately | `SUBSCRIPTION_STATE_ACTIVE` |
| Terminal failure | `SUBSCRIPTION_CANCELED` or `SUBSCRIPTION_EXPIRED` | n/a | Gone | canceled/expired |

Key facts to internalize before writing any code:

- The silent grace period of about 1 day always applies, even with a 0 day configuration. It is folded into any longer grace period you set (a 7 day window means 7 total days, not 7 + 1).
- Client side `Purchase` objects look identical in grace period and in a healthy renewal: `isAutoRenewing = true`, `purchaseState == PURCHASED`. You cannot detect grace period from `queryPurchasesAsync()`. Source of truth is the server side RTDN plus `SubscriptionPurchaseV2.subscriptionState`.
- Grace period `expiryTime` points to the end of the grace window, not the original renewal date.
- On recovery, Google resets the billing date to the recovery date. Persist the new `expiryTime` from `SubscriptionPurchaseV2`; cached pre failure dates will be wrong.
- If you disable account hold, the subscription cancels immediately after grace period ends. Enabling both (for example 7 day grace + 30 day hold = 37 day recovery window) is the usual recommendation.

## Phase 2: Plan the dunning policy

Decide these rules before you touch code. The rest of the skill is mechanical once this is set.

### Stage to action mapping

| Stage | Entitlement | Primary UI | Secondary channels | Urgency |
|---|---|---|---|---|
| Silent grace period | Keep | none (you do not see the RTDN) | none | n/a |
| Grace period | Keep | Dismissible banner on main screen | Push on day 0, email by day 3, optional `showInAppMessages(TRANSACTIONAL)` at natural launch points | Soft, informational |
| Account hold | Revoke | Full screen account hold screen with single CTA | Push on transition, email midway through hold | High, blocking |
| Recovered | Restore | Optional toast or inline confirmation | Optional confirmation email | n/a |
| Canceled after hold | Gone | Resubscribe screen | Final email with resubscribe link | n/a |

### Messaging cadence during recovery

- Day 0 of grace period: push notification immediately on `SUBSCRIPTION_IN_GRACE_PERIOD` plus banner in app.
- Day 3 of grace period: email reminder with deep link to payment update.
- Transition to account hold: push notification plus switch app UI to full screen hold screen. Revoke entitlement in the same transaction that flips the flag.
- Midway through account hold: second email. Increase urgency wording.
- On `SUBSCRIPTION_RECOVERED`: clear both flags, restore entitlement, persist the new `expiryTime`, optional confirmation message.

### Rules you should codify

1. Never revoke during grace period. That is Google's guideline and the main retention lever.
2. Always revoke on `SUBSCRIPTION_ON_HOLD`. Do not wait for the user to open the app.
3. Treat the server flag, not `Purchase.isAutoRenewing`, as the source of truth for recovery state.
4. On `SUBSCRIPTION_RECOVERED`, overwrite the cached renewal date with the new `expiryTime`.
5. When changing grace or account hold durations, extend rather than shorten. Shortening can push subscribers already mid recovery into hold or cancellation earlier than expected. If you must shorten, monitor `SUBSCRIPTION_ON_HOLD` and `SUBSCRIPTION_CANCELED` volume after the change.

## Phase 3: Execute

### 3.1 Backend: handle the three transition RTDNs

For each RTDN, look up the purchase token, fetch `SubscriptionPurchaseV2` from the Google Play Developer API, confirm the state, then flip flags.

`SUBSCRIPTION_IN_GRACE_PERIOD`:

1. Confirm `subscriptionState == SUBSCRIPTION_STATE_IN_GRACE_PERIOD`.
2. Set `gracePeriod = true` on the user record. Keep entitlement active.
3. Trigger push notification and queue the day 3 email.

`SUBSCRIPTION_ON_HOLD`:

1. Confirm `subscriptionState == SUBSCRIPTION_STATE_ON_HOLD`.
2. Set `onHold = true`. Revoke the entitlement now.
3. Trigger push notification. Queue the midway hold email.

`SUBSCRIPTION_RECOVERED`:

```kotlin
// Server side handler
fun handleSubscriptionRecovered(token: String, pkg: String) {
    val sub = playApi.getSubscriptionV2(pkg, token)
    if (sub.subscriptionState != "SUBSCRIPTION_STATE_ACTIVE") return
    val rec = db.findByPurchaseToken(token) ?: return
    rec.status = "ACTIVE"
    rec.gracePeriod = false
    rec.onHold = false
    rec.renewalDate = sub.lineItems.firstOrNull()?.expiryTime
    db.update(rec)
}
```

After account hold expires without recovery, you get `SUBSCRIPTION_CANCELED` or `SUBSCRIPTION_EXPIRED`. Treat it like any cancellation: revoke, update, optional resubscribe email.

### 3.2 Client: drive UI from server flags

Let a single function branch on the server reported status. Do not try to derive this from `queryPurchasesAsync()`.

```kotlin
// PBL 9.x
fun handleSubscriptionState(status: SubscriptionStatus) {
    when {
        status.isOnHold -> {
            revokeEntitlement()
            showAccountHoldScreen()
        }
        status.isInGracePeriod -> {
            // keep access, show dismissible banner
            showGracePeriodBanner()
        }
        status.isActive -> grantEntitlement()
    }
}
```

### 3.3 Client: `showInAppMessages()` for payment issues

Call at natural moments (app launch, entering a subscription gated feature, or when server flags indicate grace or hold). The `TRANSACTIONAL` category covers both grace period and account hold. If there is nothing to show, the call returns `NO_ACTION_NEEDED`.

```kotlin
// PBL 9.x
fun showPaymentRecovery(activity: Activity) {
    val params = InAppMessageParams.newBuilder()
        .addInAppMessageCategoryToShow(
            InAppMessageParams
                .InAppMessageCategoryId.TRANSACTIONAL
        ).build()
    billingClient.showInAppMessages(activity, params) { r ->
        if (r.responseCode ==
            InAppMessageResult.InAppMessageResponseCode
                .SUBSCRIPTION_STATUS_UPDATED
        ) refreshSubscriptionStatus()
    }
}
```

On `SUBSCRIPTION_STATUS_UPDATED`, re sync with your backend. Google has confirmed the payment was fixed inside the dialog, but your server flag is still stale until the `SUBSCRIPTION_RECOVERED` RTDN lands.

### 3.4 Deep link to Play Store subscription management

Use this as the CTA target from banners, the hold screen, and notifications.

```kotlin
// PBL 9.x
fun openSubscriptionManagement(ctx: Context, pkg: String) {
    val uri = Uri.parse(
        "https://play.google.com/store/account/" +
            "subscriptions?package=$pkg"
    )
    ctx.startActivity(Intent(Intent.ACTION_VIEW, uri))
}
```

### 3.5 Verification checklist

- Grace period path: trigger a test renewal failure, confirm `SUBSCRIPTION_IN_GRACE_PERIOD` arrives, verify entitlement stays on and the banner renders.
- Hold path: wait for grace to expire, confirm `SUBSCRIPTION_ON_HOLD` arrives, verify entitlement is revoked and the hold screen blocks premium features.
- Recovery path: fix the payment method, confirm `SUBSCRIPTION_RECOVERED` arrives, verify flags clear, entitlement restores, and `renewalDate` equals the new `expiryTime` from `SubscriptionPurchaseV2`.
- Terminal path: let account hold expire, confirm `SUBSCRIPTION_CANCELED` or `SUBSCRIPTION_EXPIRED` arrives, verify the resubscribe UI appears.
- Silent window: confirm a fresh renewal failure does not fire `SUBSCRIPTION_IN_GRACE_PERIOD` immediately; the silent ~1 day must pass first.

## References

- [Full chapter](https://www.revenuecat.com/guides/google-play-billing/payment-recovery-grace-period-and-account-hold)
