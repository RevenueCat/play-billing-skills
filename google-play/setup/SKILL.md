---
name: setup
description: Use this skill when configuring Play Console, creating products, enabling service account API access, or setting up RTDN before writing billing code. You stand up the full Google Play billing environment so app and backend code can authenticate, query products, and receive server side purchase events.
license: Apache-2.0; see LICENSE
metadata:
  author: RevenueCat
  source: google-play-handbook chapter 2
  keywords:
  - android
  - play-console
  - service-account
  - rtdn-setup
  - foundations
---

## Phase 0: Intent

Use this skill when any of the following is true:

- You are starting a new Android billing integration and have not yet configured Play Console, products, API access, or RTDN.
- A teammate asks you to "set up Play billing" or "wire up server side purchase notifications" before any code lands.
- You hit errors like "This version of the app is not configured for billing through Google Play", 403 responses from the Google Play Developer API, or missing Pub/Sub test notifications, and you need to retrace the environment setup.

Outcome: a verified environment with a Play Developer account, a linked Payments profile, an internal test track build, at least one active product, a service account with the right Play Console roles, and a Pub/Sub topic receiving Real Time Developer Notifications.

## Phase 1: Discovery

Gather facts before changing anything. Ask or check:

1. Does the developer account already exist, and is it individual or organization? Organization verification can take up to two weeks.
2. Is there a verified Google Payments Center profile? Without it, you cannot create paid products or publish in app purchases.
3. What is the app's package name, signing configuration, and current Play Console upload state (any track)?
4. Which Google Cloud project hosts the service account (with the Google Play Developer API enabled) and the Pub/Sub topic?
5. Does a service account already exist for this backend, and which roles are granted in the Play Console (not only in GCP IAM)?
6. Is there an existing Pub/Sub topic, and has `google-play-developer-notifications@system.gserviceaccount.com` been granted Publisher on it?
7. Will the server side consumer use a push subscription (public HTTPS endpoint) or a pull subscription (firewalled or batched)?

If any answer is "unknown," treat it as a discovery task before executing Phase 3.

## Phase 2: Plan

Work top down. Each step unblocks the next, so do not skip ahead.

1. Register and verify the Google Play Developer Account; pay the one time $25 fee.
2. Create and verify the Google Payments Center profile and tax information.
3. Add the Play Billing Library 9.x dependency and upload a signed build to the internal test track.
4. Create at least one product (one time product or subscription) and activate it.
5. Create a service account in a Cloud project with the Google Play Developer API enabled, then invite it in Play Console Users and permissions with the billing permissions.
6. Create a Pub/Sub topic, grant Google publish access, and create a push or pull subscription.
7. Point Play Console RTDN at the full topic name and send a test notification.

Stop and re-plan if Payments verification, identity verification, or API enablement is incomplete. Later steps will silently fail otherwise.

## Phase 3: Execute

### 3.1 Play Console app setup

1. Register at `play.google.com/console`. Choose personal or organization. Both have the same Play Console features; choose organization for a business, which several alternative billing programs require.
2. Complete identity verification. Keep business registration, government issued ID, and proof of address accessible for organization accounts.
3. Create the app at **All apps > Create app**. Fill name, default language, app type, and free or paid.
4. Complete content, ads, and target audience declarations and add a privacy policy URL. Placeholder store listing content is fine for internal testing, but the privacy policy URL is required on every track.
5. Create the Payments profile at **Setup > Payments profile** with bank, business, and tax details. Wait for verification before creating paid products.

Add the Play Billing Library to the app module `build.gradle.kts`:

```kotlin
dependencies {
    val billingVersion = "9.1.0"
    implementation(
        "com.android.billingclient:billing-ktx:$billingVersion"
    )
}
```

If the project uses a version catalog, define the version in `libs.versions.toml`:

```toml
[versions]
billing = "9.1.0"

[libraries]
billing-ktx = { module = "com.android.billingclient:billing-ktx", version.ref = "billing" }
```

Pin the version explicitly. PBL 9 needs `minSdk` 23 or higher and `compileSdk` 35 or higher (it brings in androidx.core 1.15.0, whose AAR metadata requires compileSdk 35). The library's own targetSdk does not set yours: Google Play has required new apps and updates to target API 36 since August 31, 2026. billing-ktx 9.x needs Kotlin 2.2 or newer; on an older Kotlin, upgrade Kotlin or use `com.android.billingclient:billing` with the listener APIs. An up to date Google Play Store app must be on the test device. Confirm `google()` and `mavenCentral()` are present in `settings.gradle.kts`.

Upload to the internal test track:

1. Build a signed APK or App Bundle. Use Play App Signing on the first upload.
2. Go to **Testing > Internal testing** and create a new release.
3. Upload the artifact and add testers by Google account email.
4. Roll out. Testers must accept the opt in link before installing from the Play Store.

Internal releases publish in minutes with no review. Use closed testing (up to 200 email lists) or open testing for broader audiences later.

### 3.2 Product and subscription creation

Create a one time product:

1. Go to **Monetize with Play > Products > One-time products > Create one-time product** (consoles still on the legacy model show **In-app products**).
2. Enter a Product ID such as `remove_ads`. The ID cannot be changed or reused once the product is created.
3. Set name, description, tax and compliance settings, then add a purchase option (Buy or Rent) with regional prices.
4. Click **Activate**.

Use a `<category>_<descriptor>` naming scheme (`premium_monthly`, `coins_500`, `remove_ads`). Keep IDs lowercase with underscores. Do not encode prices or promotions in the ID.

For subscriptions, create a Subscription, then add Base Plans and Offers inside it. A consistent scheme such as `premium_monthly` (subscription), `standard` (base plan), and `intro-7d-free` (offer) stays readable during later debugging. Base plan and offer IDs allow only lowercase letters, digits and hyphens. Product IDs allow lowercase letters, digits, underscores and periods, but no hyphens.

Newly activated products can take a few minutes to propagate. If `queryProductDetails` returns empty immediately after activation, wait and retry.

### 3.3 Service account provisioning for the Google Play Developer API

Create the service account in GCP, then grant Play Console roles separately.

1. In the Google Cloud Console, select or create a project and enable the Google Play Android Developer API for it.
2. Go to **IAM & Admin > Service Accounts > Create Service Account** and name it (for example `play-billing-backend`).
3. Create a JSON key and download it to a secrets manager. Do not commit it or embed it in a client.
4. In the Play Console, go to **Users and permissions > Invite new users**, enter the service account email, and grant the permissions below.

Grant only the roles the backend needs. Play Console permissions are separate from GCP IAM.

| Play Console permission | Purpose | Grant when |
| --- | --- | --- |
| View financial data, orders, and cancellation survey responses | Required by the Google Play Billing APIs | Always, for any billing backend |
| Manage orders and subscriptions | Verify and acknowledge purchases, cancel, defer, revoke, refund | Always, for any billing backend |
| Admin (all permissions) | Full account control | Avoid unless a specific task requires it |

Use separate service accounts for separate purposes (for example, purchase verification versus analytics). Rotate keys periodically; up to 10 keys per service account are allowed so you can deploy a new key before deleting the old. For Cloud Run, GKE, or App Engine, prefer workload identity federation over downloaded key files.

Test API access with a read call such as listing in app products:

```kotlin
// Server side Kotlin using google-api-services
val transport = GoogleNetHttpTransport.newTrustedTransport()
val credential = GoogleCredentials
    .fromStream(FileInputStream("service-account.json"))
    .createScoped(
        "https://www.googleapis.com/auth/androidpublisher"
    )
val publisher = AndroidPublisher.Builder(
    transport,
    GsonFactory.getDefaultInstance(),
    HttpCredentialsAdapter(credential)
).setApplicationName("your-app").build()
```

### 3.4 Pub/Sub topic and RTDN configuration

Create the topic:

1. In the Google Cloud Console, go to **Pub/Sub > Topics > Create Topic**.
2. Name it descriptively (for example `play-billing-notifications`).
3. Keep default settings and create.

Grant Google publish access:

1. Open the topic and click **Permissions**.
2. Add principal `google-play-developer-notifications@system.gserviceaccount.com`.
3. Assign role **Pub/Sub Publisher**.

Create a subscription. Pick the delivery model that matches your infrastructure.

| Subscription type | How it delivers | Choose when |
| --- | --- | --- |
| Push | Pub/Sub sends HTTP POST with a base64 JSON payload; endpoint must return 2xx | You have a public HTTPS endpoint and want the simplest path |
| Pull | Your server calls the Pub/Sub API to fetch and acknowledge messages | Server sits behind a firewall, batches work, or needs concurrency control |

Configure a dead letter topic. Pub/Sub keeps retrying failed messages until they expire, then drops them. Set a maximum delivery attempt count (allowed between 5 and 100) so undeliverable messages land on the dead letter topic rather than looping. Monitor the dead letter topic; messages there are events your system did not process.

Each RTDN message payload looks like:

```kotlin
// Decoded Pub/Sub message payload
{
    "version": "1.0",
    "packageName": "com.example.app",
    "eventTimeMillis": "1234567890123",
    "subscriptionNotification": {
        "version": "1.0",
        "notificationType": 4,
        "purchaseToken": "abc123..."
    }
}
```

The notification carries only the token; call `purchases.subscriptionsv2.get` and read `lineItems[].productId` to learn the product.

Enable RTDN in the Play Console:

1. Go to **Monetize > Monetization setup**.
2. Check **Enable real-time notifications** and enter the full topic name `projects/your-project-id/topics/play-billing-notifications`.
3. If you sell one time products, choose **Get all notifications for subscriptions and one-time products**; the other option sends no one time product purchase events.
4. Save changes.

## Phase 4: Verify

Send a test notification and walk the environment checklist.

1. In the Play Console RTDN settings, click **Send Test Message**.
2. Confirm the message arrives at the Pub/Sub subscription. For push, confirm the endpoint received an HTTP POST and returned 200.
3. The payload contains a `testNotification` field instead of `subscriptionNotification` or `oneTimeProductNotification`. The handler should acknowledge it without treating it as a real event.

If the test never arrives, check each link in the chain:

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| "This version of the app is not configured for billing through Google Play" | App not on a test track, version code mismatch, or wrong signing key | Install the exact signed build uploaded to the Play Console |
| `queryProductDetails` returns empty | Product not Active, wrong ID or type, or propagation delay | Activate the product; verify ID and INAPP vs SUBS; wait a few minutes |
| 403 from Google Play Developer API | Service account missing Play Console permissions, or the API is not enabled in its Cloud project | Invite the service account in **Users and permissions** with both billing permissions; enable the Google Play Android Developer API |
| RTDN test never arrives | Wrong topic name, missing Publisher role, unreachable push endpoint | Match full topic name; grant Publisher to `google-play-developer-notifications@system.gserviceaccount.com`; verify HTTPS endpoint returns 200 |
| Tester is charged real money or sees no test instruments | Account is not a license tester, or a different device account is paying | Add it under **Settings > License testing**; the account that downloaded the app (or the first account on the device) makes the purchase |
| Gradle fails to resolve billing library | Missing repositories or proxy block | Add `google()` and `mavenCentral()` in `settings.gradle.kts`; configure proxy if needed |

Final environment checklist:

- [ ] Google Play Developer Account registered and verified
- [ ] Google Payments Center profile linked and verified
- [ ] Play Billing Library 9.x pinned in app dependencies
- [ ] App uploaded to the internal test track
- [ ] At least one product created and activated
- [ ] Service account created with minimum Play Console roles
- [ ] Cloud Pub/Sub topic created with Google Publisher permission
- [ ] Push or pull subscription configured (with dead letter topic)
- [ ] RTDN enabled in Play Console pointing to the full topic name
- [ ] Test notification sent and acknowledged

When every item is checked, the environment is ready for the billing code that follows in later chapters.

## References

- [Full chapter](https://www.revenuecat.com/guides/google-play-billing/setting-up-your-environment)
