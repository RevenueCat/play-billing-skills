---
name: security
description: Use this skill when hardening a RevenueCat integration on Android. Covers Trusted Entitlements response verification (INFORMATIONAL by default, with no public ENFORCED mode on Android), why the server is always the authority, API key hygiene (public SDK key vs secret REST key), anonymous user identity, and purchase token protections RevenueCat provides automatically.
license: Apache-2.0; see LICENSE
metadata:
  author: RevenueCat
  source: revenuecat-handbook chapter 15
  keywords:
  - android
  - revenuecat
  - security
  - trusted-entitlements
  - entitlement-verification-mode
  - api-key
  - anonymous-user
---

## Phase 0: Intent

Tell the user: "I will review your RevenueCat security posture on Android: verification mode, API keys, user identity, and server side access decisions."

## Phase 1: Discovery

Confirm what RevenueCat already covers so you can focus on the real gaps.

| Concern | Who handles it | How |
|---|---|---|
| Receipt validation against Google Play | RevenueCat backend | Runs before `awaitPurchase()` returns |
| Purchase token reuse | RevenueCat backend | Tokens are deduplicated server side |
| Fabricated purchase tokens | RevenueCat backend | Fails Google Play verification, no entitlement granted |
| HTTPS transport to RevenueCat | SDK | Always on |
| Retry of token post on network failure | SDK | Retries on next app launch |

Ask the project these questions:

- Is `EntitlementVerificationMode` still at its default, `INFORMATIONAL`, or did someone set it to `DISABLED`? With `DISABLED`, `CustomerInfo` responses are trusted without signature checking.
- Is the SDK configured with the public Android key (starts with `goog_`) or has someone accidentally pasted the secret key into the client?
- Are real users identified with `Purchases.logIn(yourUserId)`, or is the app still relying on anonymous `$RCAnonymousID:...`?
- Do server endpoints that serve premium content verify entitlement server side, or do they trust a client sent flag?

## Phase 2: Plan

Decide each of the following before changing code.

### Decision A: Entitlement verification mode

| Mode | Failed verification does what | Pick when |
|---|---|---|
| `INFORMATIONAL` (default since SDK 8.11.0) | Reported as `VerificationResult.FAILED`, access still granted | Keep it. Read the result and decide how your app reacts |
| `DISABLED` | No signing happens | Only for quick prototypes |

The Android SDK has no public `ENFORCED` mode, so `EntitlementVerificationMode.ENFORCED` does not compile.

### Decision B: Where is the authority?

Whatever the verification mode, the client is not the authority for paid content. Decide whether each premium endpoint:

1. Calls the RevenueCat REST API per request, or
2. Reads a local `has_entitlement` flag driven by RevenueCat webhooks.

Option 2 is cheaper at request time, option 1 has no cache staleness. Pick one, document it, do not mix per endpoint without a reason.

### Decision C: User identity

If the app is in production, plan to call `Purchases.logIn("your_user_id")` with your own authenticated user id. Anonymous ids are device scoped identifiers, not credentials, and are shared across users of the same device.

## Phase 3: Execute

### 3.1 Keep response verification on

`INFORMATIONAL` is the default, so set it only if you want the configuration to be explicit:

```kotlin
PurchasesConfiguration.Builder(context, apiKey)
    .entitlementVerificationMode(EntitlementVerificationMode.INFORMATIONAL)
    .build()
```

Read the verification result when you inspect entitlements:

```kotlin
when (customerInfo.entitlements.verification) {
    VerificationResult.VERIFIED -> { /* response is authentic */ }
    VerificationResult.FAILED -> { /* possible tampering, log and alert */ }
    VerificationResult.NOT_REQUESTED -> { /* verification disabled */ }
    VerificationResult.VERIFIED_ON_DEVICE -> { /* verified locally */ }
}
```

There is no `ENFORCED` mode to upgrade to on Android. If you want a failed signature to cost access in the app, handle `VerificationResult.FAILED` in your own code, and keep the server side check in 3.4 as the real gate.

### 3.2 Keep API keys in the right place

| Key | Where it lives | What it can do |
|---|---|---|
| Public Android SDK key (`goog_...`) | Embedded in the app binary | Read and purchase for the calling user only |
| Secret REST API key | Your server, secret manager or env var | Full REST API, admin operations, grant entitlements |

In Android code, only the public key appears:

```kotlin
Purchases.configure(
    PurchasesConfiguration.Builder(context, "goog_PUBLIC_android_sdk_key").build()
)
```

Never commit the secret key to the app repo. Grep the Android source tree for the secret key prefix and confirm zero hits before release.

### 3.3 Identify real users

Call `logIn` as soon as you have an authenticated user id:

```kotlin
val result = Purchases.sharedInstance.awaitLogIn("your_user_id")
val customerInfo = result.customerInfo
```

Do not rely on the anonymous id as a credential. It is a device scoped identifier and does not protect purchase history on shared devices.

### 3.4 Enforce on the server, not on the client

Whatever the client verification mode, every server endpoint that serves paid content checks entitlement server side:

```python
def get_premium_content(user_id):
    info = revenuecat.get_subscriber(user_id)
    if not info.entitlements["pro"].is_active:
        raise Forbidden()
    return content
```

Or read a local `has_pro` flag driven by RevenueCat webhooks and check that flag per request.

## Phase 4: Verify

- [ ] Android source contains only the public SDK key. Secret key grep is clean.
- [ ] `EntitlementVerificationMode` is not `DISABLED` (the default `INFORMATIONAL` is fine) and telemetry for `VerificationResult.FAILED` is watched.
- [ ] Real users are identified through `Purchases.logIn`. Anonymous ids are only used for pre login flows.
- [ ] Every paid content endpoint on your server verifies entitlement through the REST API or a webhook driven flag. None trust a client header.

## Common mistakes

| Mistake | Why it hurts | Fix |
|---|---|---|
| Shipping the secret key in the app | An attacker who decompiles the APK can call admin REST endpoints | Public key in app, secret key only on server |
| Setting the mode to `DISABLED` in production | A man in the middle can forge `CustomerInfo` responses | Keep the default `INFORMATIONAL` and watch `VerificationResult.FAILED` |
| Treating the anonymous id as a credential | It is not secret and is shared across users of the same device | Call `logIn` with your authenticated user id |
| Trusting `customerInfo` from the client on the server | A tampered client can claim any entitlement | Verify on the server via REST API or webhook driven DB |

## References

- [Full chapter](https://www.revenuecat.com/guides/revenuecat-android-sdk/security)
