---
name: understanding-billing
description: Use this skill when a developer is new to Google Play Billing or needs to orient themselves before picking an implementation task. Maps their goal to the right pillar (Play Billing Library, Google Play Developer API, Play Console plus RTDNs) and routes them to the concrete skill to invoke next.
license: Apache-2.0; see LICENSE
metadata:
  author: RevenueCat
  source: google-play-handbook chapter 1
  keywords:
  - android
  - play-billing
  - architecture
  - foundations
---

## Phase 0: Intent

Tell the user: "I will orient you to Google Play Billing's three pillars, map your goal to the right pillar, and point you at the concrete skill to run next."

## Phase 1: Discovery

Before touching code, confirm the developer understands the three pillars and the four actors. Each pillar owns a different slice of the system:

| Pillar | Surface | Role |
| --- | --- | --- |
| Play Billing Library (PBL) | Android client, Gradle dep `com.android.billingclient:billing-ktx` | Query products, launch purchase dialog, receive results on device |
| Google Play Developer API | Server REST API at `androidpublisher.googleapis.com` | Verify purchases, manage subscriptions, manage catalog. Source of truth |
| Google Play Console | Web dashboard | Create products, set prices, configure RTDNs and API access |

A fourth piece, Cloud Pub/Sub, carries Real Time Developer Notifications (RTDNs) from Google to your backend when purchase or subscription state changes.

The four actors in every transaction:

| Actor | Responsibility |
| --- | --- |
| Your app | Query products, launch purchase flow, forward purchase tokens to backend |
| Google Play Services | System service that renders the purchase dialog and talks to Google's servers |
| Your backend | Verify tokens against the Developer API, store entitlements, process RTDNs |
| Google Play servers | Process payments, run renewals and payment recovery, emit RTDNs |

Ask the developer which of these surfaces they already have set up: Play Console account, service account credentials, Pub/Sub topic, backend, Android app.

## Phase 2: Plan

Map the developer's goal to the pillar(s) they need, then to the next skill.

| Developer goal | Primary pillar | Next skill |
| --- | --- | --- |
| First time onboarding, no account yet | Play Console | `google-play/setup` |
| Show prices and launch a purchase from the app | PBL | `google-play/integrating-pbl` |
| Verify a purchase token on the server | Developer API | `google-play/server-verification` |
| Receive renewal and cancellation events | RTDN plus Developer API | `google-play/rtdn` |
| Create or edit products, base plans, offers | Play Console or catalog API | `google-play/catalog` |
| Handle subscription lifecycle states | Developer API plus RTDN | `google-play/subscription-lifecycle` |

Decision notes and tradeoffs:

- Treat the Developer API as the source of truth. PBL is convenience. Your backend should verify every purchase token before granting entitlements.
- Acknowledge every purchase within 3 days. Unacknowledged purchases auto refund.
- PBL feature availability depends on the Google Play Services version on the device. Use `isFeatureSupported()` before calling feature specific APIs.
- Subscriptions have a lifecycle (active, paused, grace period, on hold, canceled, expired). Plan for state handling on the server side, not just the app.
- Entitlements are your problem. Google does not store what each user has access to.

## Phase 3: Execute

This chapter is conceptual. There is no code to run here. Route the developer to the implementation skill that matches the goal you identified in Phase 2.

Core vocabulary the next skill will assume you know:

| Term | Meaning |
| --- | --- |
| Product ID (SKU) | Unique string per product, for example `premium_monthly`. Cannot be reused after deletion |
| Purchase Token | Google generated string identifying a transaction. Primary key for server verification |
| Order ID | Financial transaction ID. Subscriptions append a sequence like `GPA.1234-5678-9012..1` per renewal |
| Entitlement | The access you grant after verifying a purchase. You track this, not Google |
| Acknowledgement | Required confirmation within 3 days or Google refunds the purchase |
| Consumption | Marks a consumable one time product as used so it can be bought again. Implicitly acknowledges |
| Base Plan | A billing period plus price inside a subscription product |
| Offer | Promotional phase on a base plan (trial, intro price). Emits an offer token for purchase |
| RTDN | Push notification via Cloud Pub/Sub when purchase or subscription state changes |
| Linked Purchase Token | Points a new token back to the prior one on upgrade or downgrade. Follow the chain on the server |

Product types the next skill will branch on:

| Type | Subtype | Notes |
| --- | --- | --- |
| One time | Consumable | Buyable repeatedly after consumption. Virtual currency, boosts |
| One time | Non consumable | Permanent. Ad removal, unlocks |
| Subscription | `auto-renewing` | Standard recurring. Google charges until canceled |
| Subscription | Prepaid | Fixed period, no auto renewal. User tops up to extend |
| Subscription | Installment | Select markets (BR, FR, IT, ES). Minimum payment commitment |

High level purchase flow the next skill will implement:

1. App queries product details through PBL.
2. App shows products with localized prices.
3. User taps Buy. App calls `launchBillingFlow()`.
4. Google Play dialog collects payment.
5. Google processes payment. May enter pending for cash payments.
6. PBL fires `PurchasesUpdatedListener`.
7. App sends purchase token to backend.
8. Backend calls Developer API to verify.
9. Backend records entitlement, app unlocks content.
10. Backend acknowledges within 3 days. For subscriptions, backend processes RTDNs for the rest of the lifecycle.

## Phase 4: Verify

Sanity check the developer's understanding before moving on:

- Can they name the three pillars and what each one owns?
- Do they know which pillar is the source of truth? (Answer: Google Play Developer API)
- Do they know the acknowledgement deadline? (Answer: 3 days, else auto refund)
- Can they state whether their product is one time (consumable vs non consumable) or subscription (auto renewing, prepaid, installment)?
- Do they know that entitlement tracking is their responsibility, not Google's?
- Have they picked the next skill to invoke based on the Phase 2 table?

If any answer is unclear, re-read the relevant section of the full chapter before proceeding. If the developer is trying to sell physical goods, services performed in the physical world, peer to peer payments, or content consumable outside the app, Google Play Billing is not required. Chapter 18 covers alternative billing in regulated regions (South Korea, EEA, India, United States).

## References

- [Full chapter](https://www.revenuecat.com/guides/google-play-billing/understanding-google-plays-billing-system)
