# Salesforce Consent & Preference Center

[![CI](https://github.com/DavidZernik/sf-consent-center/actions/workflows/ci.yml/badge.svg)](https://github.com/DavidZernik/sf-consent-center/actions/workflows/ci.yml)
[![Deploy](https://github.com/DavidZernik/sf-consent-center/actions/workflows/deploy.yml/badge.svg)](https://github.com/DavidZernik/sf-consent-center/actions/workflows/deploy.yml)

**Live demo → https://davidzernik.github.io/sf-consent-center/**

A working Salesforce application built as a portfolio piece by
[David Zernik](https://davidz-losangeles.com/): marketing consent captured in CRM, resolved across
a Data Cloud unified profile, and activated into Marketing Cloud.

The demo runs in your browser. The Lightning Web Components are real — compiled with the `@lwc`
toolchain against Salesforce's published `lightning-base-components` package, from the same source
files that would deploy to an org. The Apex is real, deployable source; it cannot execute outside a
Salesforce org, so the browser serves the identical JSON contract from a mock layer.

Open the **Capability Map** tab in the demo to jump from any capability straight to the code that
implements it.

---

## Why this problem

Consent is a good demo subject because it is unforgiving. It spans the whole platform, every part
of it has a correctness requirement you can argue about, and the failure modes are real:

- Somebody opts out and a campaign goes out anyway.
- The same person exists three times in CRM and only one record got the opt-out.
- A bulk load applies yesterday's decision on top of today's.
- A retry loop re-sends the same row until the org hits its async limit.

Each of those is handled explicitly in this repository, and each one has a test that fails if the
handling is removed.

---

## What is in here

| Capability | Where |
|---|---|
| **Apex** — service / selector / domain layers, explicit DTOs at the UI boundary | [`ConsentService.cls`](force-app/main/default/classes/ConsentService.cls), [`ConsentSelector.cls`](force-app/main/default/classes/ConsentSelector.cls) |
| **Triggers** — one per object, handler class, recursion + bypass guards | [`ConsentPreferenceTrigger.trigger`](force-app/main/default/triggers/ConsentPreferenceTrigger.trigger), [`ConsentPreferenceTriggerHandler.cls`](force-app/main/default/classes/ConsentPreferenceTriggerHandler.cls) |
| **Lightning Web Components** — 9 components | [`force-app/main/default/lwc/`](force-app/main/default/lwc/) |
| **Visualforce** — proof-of-consent PDF, `renderAs="pdf"` | [`ConsentCertificate.page`](force-app/main/default/pages/ConsentCertificate.page) |
| **Flows** — record-triggered Flow → bulk-safe invocable Apex | [`Consent_Unsubscribe_Request.flow-meta.xml`](force-app/main/default/flows/Consent_Unsubscribe_Request.flow-meta.xml), [`ConsentFlowActions.cls`](force-app/main/default/classes/ConsentFlowActions.cls) |
| **SOQL + SOSL** — `USER_MODE` queries, single-round-trip cross-object search | [`ConsentSelector.cls`](force-app/main/default/classes/ConsentSelector.cls) |
| **Batch Apex** — stateful nightly backfill | [`ConsentSyncBatch.cls`](force-app/main/default/classes/ConsentSyncBatch.cls) |
| **Queueable Apex** — chained retries, exponential backoff, attempt ceiling | [`SfmcSyncQueueable.cls`](force-app/main/default/classes/SfmcSyncQueueable.cls) |
| **REST — outbound** — Data Extension writes, retryable/permanent classification | [`SfmcClient.cls`](force-app/main/default/classes/SfmcClient.cls) |
| **REST — inbound** — `@RestResource`, per-record outcomes, 200/207/400/413 | [`ConsentApiResource.cls`](force-app/main/default/classes/ConsentApiResource.cls) |
| **SOAP** — Subscriber status via SOAP, `Dom.Document` parsing | [`SfmcSoapClient.cls`](force-app/main/default/classes/SfmcSoapClient.cls) |
| **OAuth** — client credentials + Data Cloud token exchange, three-tier cache | [`SfmcAuth.cls`](force-app/main/default/classes/SfmcAuth.cls), [`DataCloudAuth.cls`](force-app/main/default/classes/DataCloudAuth.cls) |
| **ETL / Informatica pattern** — staging object + promotion batch | [`ConsentStagingBatch.cls`](force-app/main/default/classes/ConsentStagingBatch.cls) |
| **Data Cloud** — Query API v2, DMOs, identity resolution, Calculated Insight | [`DataCloudService.cls`](force-app/main/default/classes/DataCloudService.cls), [`DataCloudClient.cls`](force-app/main/default/classes/DataCloudClient.cls) |
| **Security** — `USER_MODE`, least-privilege permission set, SQL injection defence | [`DataCloudQuery.cls`](force-app/main/default/classes/DataCloudQuery.cls), [`Consent_Center_User.permissionset-meta.xml`](force-app/main/default/permissionsets/Consent_Center_User.permissionset-meta.xml) |
| **Testing** — 14 Apex test classes, 80 Jest assertions | [`*Test.cls`](force-app/main/default/classes/), [`__tests__/`](force-app/main/default/lwc/) |

---

## Four decisions worth reading the code for

**Consent resolves across the unified profile, most-restrictive-wins.**
A person with three CRM records has one consent position, not three. If any source says opted out,
the unified answer is opted out — the only rule that fails safe when systems disagree. The UI shows
*which* source decided the outcome, because "opted out" invites the question "says who?".
→ [`DataCloudService.resolveConsent`](force-app/main/default/classes/DataCloudService.cls)

**Data Cloud SQL has no bind variables.**
The Query API takes ANSI SQL as a string, so every value is interpolated by hand. `String.escapeSingleQuotes`
is a *SOQL* helper and does not cover the backslash escape or comment sequences ANSI SQL honours.
Literals and identifiers are allowlisted rather than escaped.
→ [`DataCloudQuery.cls`](force-app/main/default/classes/DataCloudQuery.cls) · [tests](force-app/main/default/classes/DataCloudQueryTest.cls)

**The sync job writes its own status back to the record it syncs.**
Without a check on *which* fields changed, that write re-triggers the sync, which writes again —
until the org hits its async limit. The trigger only re-queues when a marketing-relevant field moved.
→ [`ConsentPreferenceTriggerHandler.enqueueSync`](force-app/main/default/classes/ConsentPreferenceTriggerHandler.cls)

**SOAP is not legacy here, it is required.**
Marketing Cloud REST can write Data Extension rows but cannot set a Subscriber's account-level
status. A global unsubscribe — the one that actually suppresses a person across every send — is only
exposed via the SOAP Subscriber object. SOAP also reports application errors inside an HTTP 200, so
the response is parsed and checked on `OverallStatus`.
→ [`SfmcSoapClient.cls`](force-app/main/default/classes/SfmcSoapClient.cls)

---

## Deploy it to your own org

This is a standard SFDX project. Nothing about the browser demo touches the metadata.

```bash
sf org create scratch --definition-file config/project-scratch-def.json --alias consent --set-default
sf project deploy start --target-org consent
sf org assign permset --name Consent_Center_User --target-org consent
sf apex run test --target-org consent --code-coverage --result-format human
```

The two Named Credentials point at placeholder hosts — set your own Marketing Cloud tenant and
My Domain before exercising the callouts. Data Cloud DMO and Calculated Insight API names vary by
data space; adjust the constants at the top of `DataCloudService`.

---

## Run the demo locally

```bash
npm ci
npm run build     # smoke checks → source manifest → assets → bundle
npm run dev       # serves dist/ on :8080
```

Other scripts:

| Command | What it does |
|---|---|
| `npm test` | Jest component tests |
| `npm run lint` | ESLint with the LWC rule set |
| `npm run smoke` | Exercises the demo data layer before anything is bundled |
| `npm run lint:apex` | PMD over the Apex (needs Java + PMD on `PATH`) |

---

## How the browser demo works

The interesting constraint: **Apex cannot run outside a Salesforce org, and platform LWC imports do
not resolve in a plain browser.** Rather than fork the components, the build swaps the import map.

Components import Apex exactly as they would on-platform:

```js
import getConsentSummaries from '@salesforce/apex/ConsentService.getConsentSummaries';
```

[`lwc.config.json`](lwc.config.json) maps that specifier to a browser mock, and maps the `c/`
namespace onto the real SFDX component paths. The component source is byte-identical between the
demo, the org, and the test suite — only the module resolution differs.

The mock layer resolves asynchronously with realistic latency and returns errors in the same
`{ body: { message } }` shape the Apex boundary produces, so components exercise their real loading
and error branches. Mock payload shapes mirror the Apex DTOs field for field; if the two disagree,
the demo is lying about the contract.

Two other pieces the platform normally provides are reimplemented in the shell: `ShowToastEvent`
(a `lightning__showtoast` CustomEvent, caught at the shell boundary and rendered) and
`NavigationMixin` (a real mixin whose `Navigate` becomes a hash route). Both use the genuine
platform API on the component side.

One deliberate choice worth flagging: the demo runs LWC in **synthetic shadow**, as Lightning
Experience does. SLDS is a document-level stylesheet, and native shadow roots block it — so under
native shadow every `slds-*` class inside a component silently stops applying.

### Deep links

Any file can be linked directly:

```
#/source/force-app%2Fmain%2Fdefault%2Fclasses%2FConsentService.cls
```

---

## CI

Everything runs without a Salesforce org, so the badges mean something to a reader who has not
authorised anything:

- **ESLint** with the LWC rule set — including `valid-api` and `no-leaky-event-listeners`, which
  catch component bugs that are invisible in review. (`valid-api` would have caught the one real
  bug found while building this: a `show()` method that was not `@api`, leaving every toast in the
  app silently dead.)
- **Jest** — 80 assertions across the components, the router, the source viewer and the intro.
- **Smoke checks** on the demo data layer, because a module-scope error builds cleanly and then
  ships a blank page.
- **PMD** static analysis over the Apex — SOQL-in-loops, sharing violations, SOQL injection.
- **Structure checks** — every Apex class has its `-meta.xml`, every LWC bundle has a template and
  metadata, and no Apex class exists without a test class referencing it.

Deploys to GitHub Pages on green, after verifying the built artifact is actually publishable.

---

## Honest notes

- **The Apex does not execute in the demo.** It is real, deployable source with real tests; the
  browser serves the same contract from a mock. Deploy it to a scratch org to see it run.
- **Visualforce cannot render outside an org** — `renderAs="pdf"` is server-side. The page and its
  controller are in the repository and in the source viewer; the demo links to the real
  `/apex/ConsentCertificate?id=` URL rather than faking a PDF.
- **Data Cloud DMO and Calculated Insight names vary per org.** The names used follow the standard
  model and are constants at the top of `DataCloudService`.
- **Seed data is fabricated** and deterministic, using `.example` / `.invalid` addresses. No real
  person's data appears anywhere in this repository.

---

## Licence

MIT — see [LICENSE](LICENSE).
