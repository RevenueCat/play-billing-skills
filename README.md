# Play Billing Skills

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Skills](https://img.shields.io/badge/skills-45-brightgreen.svg)](#skill-index)
[![purchases-android](https://img.shields.io/badge/purchases--android-10.x-FF5C5C.svg)](https://github.com/RevenueCat/purchases-android)
[![Platform](https://img.shields.io/badge/platform-Android-3DDC84.svg)](#scope)

Play Billing Skills turns RevenueCat's two billing handbooks, the [Google Play Billing handbook](https://www.revenuecat.com/guides/google-play-billing) and the [RevenueCat Android SDK handbook](https://www.revenuecat.com/guides/revenuecat-android-sdk), into agent ready instruction recipes for billing on Android. Each skill is task oriented. You ask your agent to "set up RTDN", "handle a failed renewal", or "migrate to Play Billing Library 9", and the matching skill walks the agent through the API calls, response codes, verification steps, and the pitfalls developers hit in production.

Claude Code supports these skills natively through the skill system. Android Studio Agent mode, Gemini CLI, Cursor, and other AI coding agents can use the same recipes as plain markdown by pointing the tool at the relevant skill directory.

This repository is a companion to the two guides above and the official Google Play and RevenueCat docs. It does not replace them or the dashboard configuration they describe. It gives the agent the specific patterns, error codes, subscription state transitions, and common pitfalls that separate a billing integration that works in a demo from one that survives grace periods, account holds, refunds, and price changes in production.

## Two collections, one repo

The skills are split into two collections that answer the same questions at two layers of abstraction:

| Collection | Layer | Use it when | Source guide |
|---|---|---|---|
| [`google-play/`](google-play/) | Raw Play Billing Library, Google Play Developer API, RTDN | You integrate `BillingClient` directly and run your own receipt verification backend. | [Google Play Billing handbook](https://www.revenuecat.com/guides/google-play-billing) |
| [`revenuecat/`](revenuecat/) | RevenueCat Android SDK, REST API, webhooks | You let RevenueCat abstract `BillingClient`, the Play Developer API, and RTDN behind a single SDK. | [RevenueCat Android SDK handbook](https://www.revenuecat.com/guides/revenuecat-android-sdk) |

Every skill distills one section of its source guide into a workflow an agent can execute. Several slugs intentionally appear in both collections (`setup`, `purchase-flow`, `plan-changes`, `error-handling`, and others) because the task is the same but the implementation differs. If you are unsure which layer you want, start with [`revenuecat/revenuecat-vs-raw-billing`](revenuecat/revenuecat-vs-raw-billing/). It lays out, side by side, what each layer handles and what stays your responsibility.

## What the skills cover

Both collections follow the same lifecycle spine, so the skills group into the same themes:

- **Foundations**: orient to the platform, set up the environment, and wire the SDK or `BillingClient`.
- **Catalog and products**: model subscriptions, sell one time products, and manage the catalog.
- **Purchasing**: run the purchase flow, switch plans, and roll out price changes.
- **Subscription lifecycle**: read subscription state and handle cancellations, pauses, winback, and payment recovery.
- **Server side**: verify purchases on a backend, process RTDN and webhooks, and harden against fraud.
- **Reference and migration**: look up response codes and API endpoints, and migrate across Play Billing Library versions.

The full list of all 45 skills, with a one line description and a link for each, is in the [Skill index](#skill-index) at the bottom.

## Quickstart

After installing (see below), open Claude Code in your project and ask for a task in plain language. Claude Code matches the request against each skill's `description` frontmatter and loads the right one.

> Set up Real Time Developer Notifications and handle a failed renewal so the user gets a grace period before losing access.

Claude Code matches "Real Time Developer Notifications" against [`gp-rtdn`](google-play/rtdn/) and "failed renewal" against [`gp-payment-recovery`](google-play/payment-recovery/), loads both, and follows the numbered workflow in each `SKILL.md`. If billing is not configured yet, those skills point back to [`gp-setup`](google-play/setup/) first. The handoffs are written into each skill's body, so the agent does not have to infer the path.

For non Claude runtimes, you trigger a skill by name. Open the skill's `SKILL.md`, or paste its path into your prompt, and the runtime follows the same workflow.

## Installation

### Claude Code (native, recommended)

Claude Code's skill loader expects each skill at `~/.claude/skills/<slug>/SKILL.md`, a flat layout. This repo nests 45 skills under two collections (`google-play/<slug>/SKILL.md` and `revenuecat/<slug>/SKILL.md`), and some slugs collide between them. The bundled install script handles both problems. It symlinks every skill into a single flat directory and prefixes each link with `gp-` or `rc-` so the two collections coexist.

```bash
git clone https://github.com/RevenueCat/play-billing-skills.git ~/play-billing-skills
~/play-billing-skills/scripts/install-skills.sh
```

The script is idempotent. Re-running it skips links that already exist, so a later `git pull` on the source repo flows through to every skill without re-running anything destructive. Useful flags:

```bash
./scripts/install-skills.sh /path/to/project/.claude/skills   # custom target directory
./scripts/install-skills.sh --only google-play                # install one collection only
./scripts/install-skills.sh --only revenuecat                 # install the other collection only
./scripts/install-skills.sh --uninstall                       # remove the links from the default target
./scripts/install-skills.sh --uninstall /path/to/target       # remove the links from a custom target
```

Restart your Claude Code session after install so the new skills register.

### Android Studio Agent mode and Gemini

These agents discover skills by scanning project local directories, and they expect the same flat `<slug>/SKILL.md` layout as Claude Code. Run the install script targeting your project's agent skills directory:

```bash
cd <your-android-project>
git clone https://github.com/RevenueCat/play-billing-skills.git .play-billing-skills-source
./.play-billing-skills-source/scripts/install-skills.sh .agent/skills
```

The source repo lives at `.play-billing-skills-source/` (safe to add to `.gitignore`) so updates are a single `git pull`. End to end behavior with these runtimes has not been independently verified. Reports are welcome on the [issue tracker](https://github.com/RevenueCat/play-billing-skills/issues).

### Claude.ai and the Claude API

Upload the relevant `SKILL.md` files as Agent Skill attachments in your workspace, or reference them inline in the system prompt for direct Anthropic API integrations. The skill loader reads the YAML frontmatter to decide when a skill applies. The skills are self contained. No external runtime is required beyond the Android toolchain you use for the verification steps.

### Other agents (manual reference)

The skill files are plain markdown. Any agent that can read a file and follow its instructions can use these recipes. The auto trigger is specific to Claude Code, so other agents load a recipe when you tell them to.

- **Cursor**: drop a rule under `.cursor/rules/` that points at the skill directory.
- **Codex CLI or Gemini CLI**: add a pointer in `AGENTS.md` or `GEMINI.md` to the skill directory and instruct the agent to follow the `SKILL.md` when the user mentions a related task.
- **Ad hoc**: paste the path into your prompt directly. For example, `read ./google-play/rtdn/SKILL.md and follow it`.

## How the skills work

Each skill is a directory holding a single file:

```text
<collection>/<skill-name>/
  SKILL.md     YAML frontmatter (name, description, license, metadata)
               plus a numbered workflow the agent follows step by step
```

A skill is not documentation for humans. It is operational instructions for an LLM. The frontmatter declares when the skill applies. The body is an imperative workflow with the exact API calls, response codes, and a verification step that proves the work was done. Claude Code reads the frontmatter to decide whether a skill matches the user's request, then executes the body. Other agents skip the auto match and start from the body directly.

The skills cross reference each other by name. A migration skill names its prerequisite, a fix skill names the diagnostic that should have produced its input, and the two `understanding-*` skills act as routers that send the agent to the concrete skill to invoke next. The chain is written into each body so the agent does not have to guess the path.

Every skill traces back to one of the two source guides, so its vocabulary and recommendations stay aligned with RevenueCat's published guidance. API identifiers are pinned to a version: Play Billing Library 9.x for the `google-play` collection, and RevenueCat Android SDK 10.x for the `revenuecat` collection. This keeps the agent from emitting calls that moved or were removed across majors.

## Scope

In scope:

- Billing on Android, at both the raw Play Billing Library layer and the RevenueCat SDK layer.
- The full subscription lifecycle: setup, purchase, renewal, plan and price changes, cancellation, pause, grace period, account hold, refund, and winback.
- The server side: Google Play Developer API verification, RTDN, RevenueCat webhooks, and entitlement management.

Out of scope:

- iOS, the Apple App Store, and StoreKit. These skills are Android only.
- General Android onboarding. Use the official [Play Billing](https://developer.android.com/google/play/billing) and [RevenueCat](https://docs.revenuecat.com/) docs for first principles.
- Dashboard and Play Console UI walkthroughs beyond what a billing task requires.

## Versioning

The skills target the current stable major of each layer: Play Billing Library 9.x for `google-play`, and the RevenueCat Android SDK 10.x for `revenuecat`. The three `pbl-v*-migration` skills cover moving between Play Billing Library majors. File an issue if you find a skill that has not caught up to a recent major.

| Layer | Major targeted | Reference |
|---|---|---|
| Google Play Billing Library | 9.x | <https://developer.android.com/google/play/billing/release-notes> |
| RevenueCat Android SDK (purchases-android) | 10.x | <https://github.com/RevenueCat/purchases-android/releases> |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to set up a fork and open a pull request. The code of conduct lives in [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

If you add or update a skill, check your change against the source guide it derives from: the [Google Play Billing guide](https://www.revenuecat.com/guides/google-play-billing) for the `google-play` collection, and the [RevenueCat Android SDK guide](https://www.revenuecat.com/guides/revenuecat-android-sdk) for the `revenuecat` collection. Verify every API identifier against the SDK or API it targets. Identifiers move across major versions, and skills that quote stale names degrade the agent's output in ways that are hard to notice. When a snippet is uncertain for a given version, write the conservative version and point the reader at the upstream docs rather than inventing a call.

## Skill index

### `google-play/`: raw Play Billing Library (25 skills)

Source: the [Google Play Billing guide](https://www.revenuecat.com/guides/google-play-billing).

| Skill | What it does |
|---|---|
| [`understanding-billing`](google-play/understanding-billing/) | Orient a newcomer: map the goal to the right pillar (PBL, Play Developer API, Play Console plus RTDN) and route to the next skill |
| [`setup`](google-play/setup/) | Stand up Play Console, products, service account API access, and RTDN before writing billing code |
| [`integrating-pbl`](google-play/integrating-pbl/) | Add the dependency, wire `BillingClient`, manage its connection lifecycle, and query product details (PBL 9.x) |
| [`subscriptions`](google-play/subscriptions/) | Model the three tier Subscription, Base Plan, Offer hierarchy and shape your catalog |
| [`one-time-products`](google-play/one-time-products/) | Launch, acknowledge, and consume consumables and non consumables, including pending transactions |
| [`purchase-flow`](google-play/purchase-flow/) | Build `BillingFlowParams`, launch the flow, and handle every `BillingResult` in `PurchasesUpdatedListener` |
| [`plan-changes`](google-play/plan-changes/) | Upgrades, downgrades, and plan switches with `setSubscriptionUpdateParams` and the six replacement modes |
| [`price-changes`](google-play/price-changes/) | Opt out decreases versus opt in increases, the notification timeline, and the `SUBSCRIPTION_PENDING` state |
| [`subscription-states`](google-play/subscription-states/) | Map a subscription to the seven states and decide what access to grant in each |
| [`subscription-state-diagram`](google-play/subscription-state-diagram/) | The full subscription state machine with every RTDN triggered transition in one diagram |
| [`cancellations-pauses-winback`](google-play/cancellations-pauses-winback/) | User and system cancellation, developer revoke and refund, pause and resume, and winback offers |
| [`payment-recovery`](google-play/payment-recovery/) | Grace Period versus Account Hold, the RTDN signals between stages, and the in app messaging that drives recovery |
| [`rtdn`](google-play/rtdn/) | Set up Real Time Developer Notifications end to end: Cloud Pub/Sub, message parsing, and all 22 subscription types |
| [`rtdn-reference`](google-play/rtdn-reference/) | Quick lookup for every RTDN type with integer codes, triggers, and recommended handling |
| [`catalog-management`](google-play/catalog-management/) | Manage product and subscription catalogs programmatically via the Play Developer API |
| [`play-developer-api-reference`](google-play/play-developer-api-reference/) | Quick reference for the billing related Play Developer API REST endpoints, scopes, and request shapes |
| [`backend-architecture`](google-play/backend-architecture/) | Build a backend that verifies purchase tokens, stores subscription state, and exposes a verification endpoint |
| [`security`](google-play/security/) | Harden against fraud: server side verification, replay protection, device fingerprinting, velocity checks |
| [`error-handling`](google-play/error-handling/) | Classify every response code into recoverable, non recoverable, and user driven, then build a retry plan |
| [`billing-response-codes`](google-play/billing-response-codes/) | Reference lookup for every `BillingResponseCode` and sub response code (PBL 9.x) |
| [`alternative-billing`](google-play/alternative-billing/) | User choice billing, alternative billing only, external offers, and regional eligibility |
| [`testing`](google-play/testing/) | License testers, static test responses, sandbox purchases, and subscription lifecycle acceleration |
| [`pbl-v7-to-v8-migration`](google-play/pbl-v7-to-v8-migration/) | Migrate from Play Billing Library 7.x to 8.x: breaking changes, renames, verification |
| [`pbl-v8-to-v9-migration`](google-play/pbl-v8-to-v9-migration/) | Migrate from 8.x to 9.x: the small v9 delta, `targetSdk` 35, and the reclassified error |
| [`pbl-v7-to-v9-migration`](google-play/pbl-v7-to-v9-migration/) | Migrate 7.x straight to 9.x as a two stage plan (v7 to v8, then the v8 to v9 delta) |

### `revenuecat/`: RevenueCat Android SDK (20 skills)

Source: the [RevenueCat Android SDK guide](https://www.revenuecat.com/guides/revenuecat-android-sdk).

| Skill | What it does |
|---|---|
| [`understanding-revenuecat`](revenuecat/understanding-revenuecat/) | Orient an agent to the SDK architecture and how Products, Packages, Offerings, Entitlements, and CustomerInfo connect |
| [`setup`](revenuecat/setup/) | Create the app in the dashboard, upload Google Play service account credentials, configure entitlements and offerings, get the API key |
| [`configuring-the-sdk`](revenuecat/configuring-the-sdk/) | Add and configure the SDK: Gradle dependency, `Purchases.configure`, initial app user id strategy, log level |
| [`revenuecat-vs-raw-billing`](revenuecat/revenuecat-vs-raw-billing/) | Decide RevenueCat versus raw Play Billing with a side by side of what each handles |
| [`subscriptions`](revenuecat/subscriptions/) | Model subscriptions through Offerings, Packages, StoreProduct, SubscriptionOption, PricingPhase |
| [`one-time-products`](revenuecat/one-time-products/) | Sell one time products with `awaitPurchase`, letting the SDK acknowledge or consume automatically |
| [`purchase-flow`](revenuecat/purchase-flow/) | Implement a purchase with `awaitPurchase`, read `CustomerInfo` entitlements, and restore |
| [`plan-changes`](revenuecat/plan-changes/) | Upgrades, downgrades, and plan switches via `oldProductId` and `StoreReplacementMode`, with SDK managed token chaining |
| [`price-changes`](revenuecat/price-changes/) | Roll out price changes with RevenueCat's automatic confirmation flow handling |
| [`subscription-states`](revenuecat/subscription-states/) | Gate access via `CustomerInfo` and `entitlement.isActive`, drilling into `willRenew` and `periodType` when needed |
| [`cancellations-pauses-winback`](revenuecat/cancellations-pauses-winback/) | Surface cancellation, pause, and winback state from `CustomerInfo` and the REST API |
| [`payment-recovery`](revenuecat/payment-recovery/) | Grace Period and Account Hold reflected in `CustomerInfo`, plus `showInAppMessages` |
| [`catalog-management`](revenuecat/catalog-management/) | The two sided catalog flow: create in Play Console, import or map in the RevenueCat dashboard |
| [`backend`](revenuecat/backend/) | The RevenueCat REST API: subscribers endpoint, grant and revoke entitlements, attributes, secret versus public key usage |
| [`webhooks`](revenuecat/webhooks/) | Consume webhooks: normalized event schema, full event list, idempotency, CANCELLATION versus EXPIRATION versus RENEWAL |
| [`security`](revenuecat/security/) | Trusted Entitlements verification, server as the authority, API key hygiene, anonymous identity |
| [`error-handling`](revenuecat/error-handling/) | Handle `PurchasesError`, the `PurchasesErrorCode` enum, the `userCancelled` flag, and the right UI per code |
| [`alternative-billing`](revenuecat/alternative-billing/) | Scope alternative billing work with RevenueCat 10.x: what the SDK abstracts and what needs direct integration |
| [`testing`](revenuecat/testing/) | The RevenueCat Test Store, mockk based unit testing, and a GitHub Actions CI pattern |
| [`revenuecat-api-quick-reference`](revenuecat/revenuecat-api-quick-reference/) | Quick reference for the SDK 10.x and the most used REST endpoints |

## Find this repository useful? 😻

Support it by joining the **[stargazers](https://github.com/RevenueCat/play-billing-skills/stargazers)** for this repository. ⭐

## License

```
Copyright 2026 RevenueCat, Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```
