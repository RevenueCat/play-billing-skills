---
name: alternative-billing
description: Use this skill when implementing Google Play's alternative billing programs, external offers and billing choice (PBL 5.2 through 9.1). Covers user choice billing, alternative billing only, billing choice, external transaction reporting, and the regional program eligibility.
license: Apache-2.0; see LICENSE
metadata:
  author: RevenueCat
  source: google-play-handbook chapter 18
  keywords:
  - android
  - play-billing
  - alternative-billing
  - user-choice-billing
  - external-offers
  - billing-choice
  - pbl9
---

# Alternative Billing and External Offers

Google Play exposes several programs that let you present payment paths outside Google Play billing. This skill walks you through picking the right program for your region, wiring the PBL APIs, and reporting transactions to the `externaltransactions` API within 24 hours.

## Phase 1: Discovery

Confirm program eligibility before you touch any code. Eligibility is driven by region, product type, and Play Console enrollment.

### Check enrollment

1. Open Play Console and confirm you accepted the program terms for each program you plan to use.
2. Register external URLs, subscription management links, and countries per program.
3. Record the PBL version in your `build.gradle`. Features map to PBL versions:

| Program | Minimum PBL |
|---|---|
| User choice billing | 5.2 (6.1 renamed APIs) |
| Alternative billing only | 6.1 |
| External offers (unified API) | 8.2.1 |
| External content links | 8.2.1 |
| External payment links (legacy, Japan, closed to new enrollment) | 8.3.0 |
| Billing choice | 9.1.0 |

### Map regions to programs

| Region | Available programs |
|---|---|
| South Korea | User choice billing |
| India | User choice billing |
| EEA | User choice billing, alternative billing only, billing choice (in app alternative billing, PBL 9.1+), external offers (links) |
| United States | User choice billing, alternative billing (instead of or alongside Google Play Billing), external content links |
| Japan | User choice billing, billing choice (PBL 9.1+), external payments (legacy, closed to new enrollment September 30, 2026, ends after March 31, 2027) |
| United Kingdom, Australia | User choice billing, billing choice (PBL 9.1+) |
| Brazil, Indonesia, South Africa | User choice billing |

Several programs (user choice billing pilot, external offers, external payments) require a developer account registered as a business.

### Check runtime availability

Do not hard code country lists. The PBL surfaces eligibility.

```kotlin
billingClient.isBillingProgramAvailableAsync(
    BillingProgram.EXTERNAL_OFFER,
    listener
)
```

For alternative billing only, use `isAlternativeBillingOnlyAvailableAsync()`. A `BILLING_UNAVAILABLE` result means the user or account is ineligible.

### Discovery questions to answer

- Which program(s) does your app need per region?
- Do you serve subscriptions, one time products, or both?
- Is PBL at a version that supports the target program?
- Does your backend have a job that can report transactions within 24 hours?

## Phase 2: Plan

Pick the program variant that matches your goals and region coverage.

### Program comparison

| Program | Flow | BillingClient setup | Token source |
|---|---|---|---|
| User choice billing | Google renders a choice screen | `enableUserChoiceBilling(listener)` | `UserChoiceDetails.externalTransactionToken` |
| Alternative billing only | No Google Play billing at all, info dialog required | `enableAlternativeBillingOnly()` | `createAlternativeBillingOnlyReportingDetailsAsync()` |
| External offers | Link out to a website for deals | `enableBillingProgram(EXTERNAL_OFFER)` | `createBillingProgramReportingDetailsAsync()` |
| External content links | Link out for digital content (US) | `enableBillingProgram(EXTERNAL_CONTENT_LINK)` | `createBillingProgramReportingDetailsAsync()` |
| External payment links (legacy, Japan, closed to new enrollment) | Choice screen with developer option | `enableBillingProgram(EnableBillingProgramParams)` with `EXTERNAL_PAYMENTS` and `setDeveloperProvidedBillingListener()` | `createBillingProgramReportingDetailsAsync()` |
| Billing choice | Choice screen rendered by Google or by you; pay in app or by external web link | `enableBillingProgram(EnableBillingProgramParams)` with `BillingProgram.BILLING_CHOICE` | `DeveloperProvidedBillingDetails.externalTransactionToken` (Google rendered, payment in app) or `createBillingProgramReportingDetailsAsync()` with `setDeveloperBillingType()` (developer rendered, or any external web link) |

Programs do not stack freely. Apps in external offers (EEA) may use only alternative billing without user choice for in app purchases, not Google Play Billing or user choice billing. Apps in external payments cannot offer user choice billing at the same time. Where a region has several user choice programs, an app can be enrolled in only one per region. `BillingClient.Builder.build()` rejects a client that sets both a `UserChoiceBillingListener` and a `DeveloperProvidedBillingListener`.

### Token versus ID

- `externalTransactionToken`: generated by the PBL, tied to one user and device context, attached to the initial report only. Generate a fresh token for each alternative billing flow or link out (external offers: purchases from one link out may share its token).
- `externalTransactionId`: string you generate, uniquely identifies the transaction in your system. Each renewal uses a new ID referencing the first via `initialExternalTransactionId`. Do not put PII in the ID.

### Backend plan

Before you write client code, plan these backend pieces:

1. Endpoint that receives the token from the app and starts payment in your processor.
2. Worker that calls `POST /androidpublisher/v3/applications/{packageName}/externalTransactions` within 24 hours of charge.
3. Renewal reporter that reuses `initialExternalTransactionId` without the token.
4. Refund reporter that calls `:refund` on the `externalTransactionId` of the exact transaction being refunded (for a subscription, the specific renewal, not the initial transaction).
5. Quota planning: `createexternaltransaction` and `refundexternaltransaction` share 1,200 QPM. Stagger migrations.

### User choice billing flow plan

1. User taps buy.
2. You call `launchBillingFlow()`.
3. Google renders the choice screen for eligible users.
4. Google Play path: standard `PurchasesUpdatedListener` fires.
5. Your billing path: `UserChoiceBillingListener` fires with token and products.
6. You run your payment flow, then report through `externaltransactions`.

### Alternative billing only flow plan

1. Call `isAlternativeBillingOnlyAvailableAsync()`.
2. Call `showAlternativeBillingOnlyInformationDialog()`. On `USER_CANCELED`, retry next attempt.
3. Call `createAlternativeBillingOnlyReportingDetailsAsync()` to get a fresh token.
4. Send token plus product data to your backend.
5. Complete payment in your processor.
6. Report the transaction within 24 hours.

## Phase 3: Execute

### User choice billing client

```kotlin
val userChoiceListener = UserChoiceBillingListener { details ->
    backend.startExternalPurchase(
        details.externalTransactionToken,
        details.products
    )
}

val billingClient = BillingClient.newBuilder(context)
    .setListener(purchasesUpdatedListener)
    .enablePendingPurchases(
        PendingPurchasesParams.newBuilder().enableOneTimeProducts().build()
    )
    .enableUserChoiceBilling(userChoiceListener)
    .build()
```

For subscription upgrades that stay in your billing system, set `setOriginalExternalTransactionId()` on `SubscriptionUpdateParams` to skip the choice screen.

### Alternative billing only token

```kotlin
billingClient.createAlternativeBillingOnlyReportingDetailsAsync(
    object : AlternativeBillingOnlyReportingDetailsListener {
        override fun onAlternativeBillingOnlyTokenResponse(
            result: BillingResult,
            details: AlternativeBillingOnlyReportingDetails?
        ) {
            if (result.responseCode != BillingResponseCode.OK) return
            backend.send(details?.externalTransactionToken)
        }
    }
)
```

### External offers or content links (PBL 8.2.1+)

```kotlin
val params = BillingProgramReportingDetailsParams.newBuilder()
    .setBillingProgram(BillingProgram.EXTERNAL_OFFER)
    .build()

billingClient.createBillingProgramReportingDetailsAsync(
    params,
    reportingListener
)
```

Launch the link after you persist the token:

```kotlin
val linkParams = LaunchExternalLinkParams.newBuilder()
    .setBillingProgram(BillingProgram.EXTERNAL_OFFER) // EXTERNAL_CONTENT_LINK for US content links
    .setLinkUri(Uri.parse("https://myapp.com/offer"))
    .setLinkType(LaunchExternalLinkParams.LinkType.LINK_TO_DIGITAL_CONTENT_OFFER) // required
    .setLaunchMode(
        LaunchExternalLinkParams.LaunchMode
            .LAUNCH_IN_EXTERNAL_BROWSER_OR_APP
    )
    .build()
billingClient.launchExternalLink(activity, linkParams, listener)
```

Use the same program constant in `BillingProgramReportingDetailsParams`. App downloads use `LINK_TO_APP_DOWNLOAD` and must use `LAUNCH_IN_EXTERNAL_BROWSER_OR_APP`.

### External payment links (PBL 8.3+)

> **Japan only, legacy:** the external payments program closed to new enrollments on September 30, 2026 and ends after March 31, 2027. New integrations use billing choice (PBL 9.1+, below). Keep this code only for apps already enrolled, and migrate them to billing choice before March 31, 2027.

```kotlin
val devBillingListener = DeveloperProvidedBillingListener { details ->
    backend.handleExternalPayment(details)
}

val billingClient = BillingClient.newBuilder(context)
    .setListener(purchasesUpdatedListener)
    .enablePendingPurchases(
        PendingPurchasesParams.newBuilder().enableOneTimeProducts().build()
    )
    .enableBillingProgram(
        EnableBillingProgramParams.newBuilder()
            .setBillingProgram(BillingProgram.EXTERNAL_PAYMENTS)
            .setDeveloperProvidedBillingListener(devBillingListener)
            .build()
    )
    .build()
```

Pass `DeveloperBillingOptionParams` (billing program, link URI, launch mode) to `BillingFlowParams.Builder.enableDeveloperBillingOption()` when you call `launchBillingFlow()`. The choice screen renders only when the user is in a supported country, the program is enabled on the client, and you passed a developer option.

> **PBL 9 change:** `DeveloperProvidedBillingDetails.getLinkUri()` is now `@Nullable`. The external payment link may not be resolved at selection time, so guard against both `null` and empty string before parsing it as a `Uri`:
>
> ```kotlin
> val linkUri = details.linkUri
> if (!linkUri.isNullOrEmpty()) {
>     startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(linkUri)))
> } else {
>     showExternalPaymentUnavailableState()
> }
> ```

### Billing choice (PBL 9.1+)

Billing choice is the current program for in app alternative billing (EEA) and for in app or external web link alternative billing (Japan, United Kingdom, Australia); it is also the replacement for external payment links in Japan. Google or you can render the choice screen, and payment can happen in your app or through an external web link.

```kotlin
// Google rendered choice screen, payment in your app (scenario 1A)
val devBillingListener = DeveloperProvidedBillingListener { details ->
    backend.startAlternativePurchase(details.externalTransactionToken, details.products)
}

val billingClient = BillingClient.newBuilder(context)
    .setListener(purchasesUpdatedListener) // required with billing choice
    .enablePendingPurchases(
        PendingPurchasesParams.newBuilder().enableOneTimeProducts().build()
    )
    .enableBillingProgram(
        EnableBillingProgramParams.newBuilder()
            .setBillingProgram(BillingProgram.BILLING_CHOICE)
            .setDeveloperProvidedBillingListener(devBillingListener)
            .build()
    )
    .build()
```

After connecting, confirm availability and read the choice screen type:

```kotlin
billingClient.isBillingProgramAvailableAsync(BillingProgram.BILLING_CHOICE) { result, details ->
    val choice = details.billingChoiceAvailabilityDetails
    if (result.responseCode == BillingResponseCode.OK && choice != null) {
        val googleRendered = choice.choiceScreenType == ChoiceScreenType.GOOGLE_RENDERED
        val hasExternalLink = choice.isExternalLinkAvailable
    }
}
```

Attach the program to `BillingFlowParams` when you call `launchBillingFlow()`:

```kotlin
val flowParams = BillingFlowParams.newBuilder()
    .setProductDetailsParamsList(productDetailsParamsList)
    .enableDeveloperBillingOption(
        DeveloperBillingOptionParams.newBuilder()
            .setBillingProgram(BillingProgram.BILLING_CHOICE)
            .build()
    )
    .build()
```

If the user picks Google Play, the standard `PurchasesUpdatedListener` fires. If they pick your billing, `DeveloperProvidedBillingListener` fires with `externalTransactionToken`.

Developer rendered screen: enable the program without a `DeveloperProvidedBillingListener`, call `getBillingChoiceInfoAsync()` for the Play Billing image and loyalty text, and create the token with `createBillingProgramReportingDetailsAsync()` and `setDeveloperBillingType()` (required for `BILLING_CHOICE`). Payment in your app (`DeveloperBillingType.IN_APP`): when the user taps Buy, call `showBillingProgramInformationDialog()` with that token and show your choice screen only if it returns `OK`. External web link (`DeveloperBillingType.EXTERNAL_LINK`): show your choice screen, and if the user picks your option call `launchExternalLink()` with the token and `LinkType.LINK_TO_DIGITAL_CONTENT_OFFER`; it shows the link out and parental control screens. If the user picks Google Play, call `launchBillingFlow()` as usual.

Google rendered screen with an external web link: when the user shows intent to buy, create the token with `createBillingProgramReportingDetailsAsync()` (`BILLING_CHOICE`, `DeveloperBillingType.EXTERNAL_LINK`), then pass `DeveloperBillingOptionParams` with `setBillingProgram(BillingProgram.BILLING_CHOICE)`, `setLinkUri(...)`, `setExternalTransactionToken(token)`, and `setLaunchMode(...)`. `DeveloperProvidedBillingListener` returns the same token if the user picks your link. A token is required whenever a link is used.

For subscription replacement the choice screen is not shown again. If the original purchase went through Google Play Billing, use the standard plan change flow ([plan-changes](../plan-changes/)). If it went through your billing, set `setOriginalExternalTransactionId()` on `SubscriptionUpdateParams` with the original external transaction ID; the exact flow differs by scenario (see Google's billing choice integration guide).

### Report the initial transaction

```http
POST /androidpublisher/v3/applications/{packageName}/externalTransactions?externalTransactionId=txn-1
```

```json
{
  "originalPreTaxAmount": { "priceMicros": "4990000", "currency": "USD" },
  "originalTaxAmount": { "priceMicros": "449100", "currency": "USD" },
  "transactionTime": "2026-01-15T10:30:00Z",
  "recurringTransaction": {
    "externalTransactionToken": "token_from_pbl",
    "externalSubscription": { "subscriptionType": "RECURRING" }
  },
  "userTaxAddress": { "regionCode": "US" }
}
```

Amounts use `priceMicros`. Multiply by 1,000,000. For India, include `administrativeArea` in `userTaxAddress` because tax rates vary by state.

Program details: for external offers (EEA), add `"externalOfferDetails": { "linkType": "LINK_TO_DIGITAL_CONTENT_OFFER" }` to one time and first recurring transactions (app downloads: `LINK_TO_APP_DOWNLOAD` plus `installedAppPackage` and `installedAppCategory`; purchases inside an app installed through an offer reuse the download's token and set `appDownloadEventExternalTransactionId`). For external content links (US), add `"externalContentLinkDetails": { "linkType": "LINK_TO_DIGITAL_CONTENT_OFFER" }` (app installs also need `installedAppPackage` and `externalAppCategory`). Set only the object for the transaction's own program.

### Report renewals

Drop the token, add `initialExternalTransactionId`:

```json
{
  "recurringTransaction": {
    "initialExternalTransactionId": "txn-1",
    "externalSubscription": { "subscriptionType": "RECURRING" }
  }
}
```

### Report refunds

```http
POST /androidpublisher/v3/applications/{packageName}/externalTransactions/{externalTransactionId}:refund
```

Body: `refundTime` plus either `"fullRefund": {}` or `"partialRefund": { "refundId": "...", "refundPreTaxAmount": { "priceMicros": "...", "currency": "..." } }`.

### Verification checklist

- Report every transaction within 24 hours of the charge.
- Generate a new token immediately before each link out or alternative billing flow; never cache tokens across link outs. (External offers: purchases from one link out may share its token, and purchases in an app installed through an offer reuse the download's token.)
- Confirm PBL 8.2.1 or later if you use `createBillingProgramReportingDetailsAsync()`. 8.2.0 has a bug.
- Strip PII from `externalTransactionId` and from any external link `Uri`.
- Payment method image meets the 192dp x 20dp spec before you upload to Play Console.
- Persist the token and finish any in app work before launching an external link. Users may not return to your app.

## References

- [Full chapter](https://www.revenuecat.com/guides/google-play-billing/alternative-billing-and-external-offers)
