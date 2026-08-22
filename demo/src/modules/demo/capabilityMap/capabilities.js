/**
 * The capability map: every Salesforce developer skill this application demonstrates, what it
 * means in practice, and the exact file that implements it.
 *
 * This exists because "I know Apex" is unfalsifiable and "here is the class, here is the line
 * where the recursion guard lives" is not. Each entry points at real source in this repository,
 * which the View source panel loads directly from force-app/.
 *
 * `paths` are repository-relative and must stay in sync with the tree; scripts/generate-sources.mjs
 * fails the build if any path listed here does not exist.
 */

export const CAPABILITIES = [
    {
        id: 'apex',
        group: 'Core development',
        name: 'Apex',
        summary: 'Service, selector and domain layers with explicit DTOs at the UI boundary.',
        detail:
            'ConsentService is the only class that throws AuraHandledException; everything beneath it ' +
            'throws typed exceptions. Returning explicit DTOs rather than SObjects keeps the wire ' +
            'contract stable when fields are renamed and stops unintended fields reaching the browser.',
        paths: [
            'force-app/main/default/classes/ConsentService.cls',
            'force-app/main/default/classes/ConsentSelector.cls',
            'force-app/main/default/classes/ConsentCenterException.cls'
        ],
        route: '#/records'
    },
    {
        id: 'triggers',
        group: 'Core development',
        name: 'Triggers',
        summary: 'One trigger per object, all logic in a handler, with recursion and bypass guards.',
        detail:
            'The trigger itself contains no logic. The handler switches on Trigger.operationType, and ' +
            'the after-update path only re-queues a sync when a marketing-relevant field changed, ' +
            'without that check, the sync job writing its own status back would loop until the org hit ' +
            'the async limit. A static bypass lets bulk loads suppress per-record side effects.',
        paths: [
            'force-app/main/default/triggers/ConsentPreferenceTrigger.trigger',
            'force-app/main/default/classes/ConsentPreferenceTriggerHandler.cls',
            'force-app/main/default/classes/ConsentPreferenceTriggerTest.cls'
        ]
    },
    {
        id: 'lwc',
        group: 'Core development',
        name: 'Lightning Web Components',
        summary: 'Nine components: datatables, debounced search, dirty-state tracking, composition.',
        detail:
            'Every component in this demo is the real thing, compiled with the @lwc toolchain against ' +
            'the published lightning-base-components package. Public API via @api with getter/setter ' +
            'pairs, parent/child composition, custom events that cross shadow boundaries, and cleanup ' +
            'in disconnectedCallback so a pending debounce cannot fire against a destroyed component.',
        paths: [
            'force-app/main/default/lwc/contactConsentList/contactConsentList.js',
            'force-app/main/default/lwc/consentPreferencePanel/consentPreferencePanel.js',
            'force-app/main/default/lwc/sfmcSyncConsole/sfmcSyncConsole.js'
        ],
        route: '#/records'
    },
    {
        id: 'visualforce',
        group: 'Core development',
        name: 'Visualforce',
        summary: 'Proof-of-consent certificate rendered server side as a PDF.',
        detail:
            'Deliberately not LWC. renderAs="pdf" has no Lightning equivalent, and generating a ' +
            'paginated printable document a compliance team can file is the one job Visualforce still ' +
            'does better than anything else on the platform. The controller loads everything in its ' +
            'constructor and keeps getters pure, because a getter that queries runs an unknown number ' +
            'of times during the render phase.',
        paths: [
            'force-app/main/default/pages/ConsentCertificate.page',
            'force-app/main/default/classes/ConsentCertificateController.cls'
        ]
    },
    {
        id: 'flows',
        group: 'Core development',
        name: 'Flows',
        summary: 'Record-triggered Flow calling a bulk-safe invocable Apex action.',
        detail:
            'When a Case closes with reason "Unsubscribe Request", the Flow records the opt-out through ' +
            'the same Apex path the UI uses. The invocable takes a List and returns a List of identical ' +
            'size and order. Flow bulkifies interviews behind the scenes, and a mismatched return list ' +
            'silently misassigns results. Failures come back as data, not exceptions, so one bad record ' +
            'cannot roll back the other 199.',
        paths: [
            'force-app/main/default/flows/Consent_Unsubscribe_Request.flow-meta.xml',
            'force-app/main/default/classes/ConsentFlowActions.cls',
            'force-app/main/default/classes/ConsentFlowActionsTest.cls'
        ]
    },
    {
        id: 'soql-sosl',
        group: 'Data',
        name: 'SOQL and SOSL',
        summary: 'Bound, security-enforced SOQL plus a single-round-trip SOSL search.',
        detail:
            'All SOQL runs in USER_MODE so field- and object-level security is enforced by the platform. ' +
            'Search terms are bound and escaped, never concatenated. SOSL is used where SOQL genuinely ' +
            'cannot compete: searching Contact, Lead and the consent trail together costs one indexed ' +
            'round trip instead of three LIKE scans. Note the SOSL reserved-character set differs from ' +
            "SOQL's; escapeSingleQuotes alone would leave ? and * live.",
        paths: ['force-app/main/default/classes/ConsentSelector.cls'],
        anchor: 'searchEverywhere'
    },
    {
        id: 'batch',
        group: 'Asynchronous Apex',
        name: 'Batch Apex',
        summary: 'Stateful nightly backfill, scoped so each execute maps to exactly one callout.',
        detail:
            'Batch size is pinned to SfmcClient.MAX_ROWS_PER_REQUEST at schedule time, so a chunk is ' +
            'always one HTTP call and the job cannot approach the 100-callout limit. Partial success is ' +
            'allowed via allOrNone=false: one malformed row must not discard the whole chunk. Implements ' +
            'Schedulable in the same class so there is no separate scheduler shell to maintain.',
        paths: [
            'force-app/main/default/classes/ConsentSyncBatch.cls',
            'force-app/main/default/classes/ConsentSyncBatchTest.cls'
        ]
    },
    {
        id: 'queueable',
        group: 'Asynchronous Apex',
        name: 'Queueable Apex',
        summary: 'Chained retries with exponential backoff and a hard attempt ceiling.',
        detail:
            'Queueable rather than @future because it can chain: a partial failure re-enqueues only the ' +
            'rows that failed, and the attempt count survives between attempts as instance state. ' +
            'Backoff doubles each round (1, 2, 4 minutes) and stops at four attempts, parking the row as ' +
            'Failed for a human rather than retrying forever. Outcomes are persisted before chaining so a ' +
            'failure in the next job cannot lose the audit trail.',
        paths: [
            'force-app/main/default/classes/SfmcSyncQueueable.cls',
            'force-app/main/default/classes/SfmcSyncQueueableTest.cls'
        ],
        route: '#/sync'
    },
    {
        id: 'rest-outbound',
        group: 'Integration',
        name: 'REST APIs (outbound)',
        summary: 'Marketing Cloud Data Extension writes with retryable/permanent error classification.',
        detail:
            'The judgement call worth reading is the classification: 429 and 5xx are transient and get ' +
            'retried, 401 invalidates the cached token and retries, and any other 4xx is permanent ' +
            'because replaying an identical malformed payload would fail identically. Getting that wrong ' +
            'either hammers the tenant or silently drops consent.',
        paths: [
            'force-app/main/default/classes/SfmcClient.cls',
            'force-app/main/default/classes/SfmcClientTest.cls'
        ]
    },
    {
        id: 'rest-inbound',
        group: 'Integration',
        name: 'REST APIs (inbound)',
        summary: '@RestResource endpoint with per-record outcomes and correct HTTP semantics.',
        detail:
            'Accepts a batch and answers per record rather than all-or-nothing, so a caller sending 50 ' +
            'rows learns exactly which failed. Returns 200 when everything landed, 207 Multi-Status when ' +
            'the outcome was mixed, 413 when the batch is oversized, 400 for malformed JSON. Every email ' +
            'in the payload is resolved in one query, never one lookup per row.',
        paths: [
            'force-app/main/default/classes/ConsentApiResource.cls',
            'force-app/main/default/classes/ConsentApiResourceTest.cls'
        ]
    },
    {
        id: 'soap',
        group: 'Integration',
        name: 'SOAP APIs',
        summary: 'Marketing Cloud Subscriber updates, with Dom.Document response parsing.',
        detail:
            'SOAP because REST cannot do this job: the account-level global unsubscribe (the one that ' +
            'suppresses a person across every send, which is what a legal opt-out actually means) is ' +
            'only exposed through the SOAP Subscriber object. SOAP also reports application errors ' +
            'inside an HTTP 200, so the response is parsed with Dom.Document and checked on ' +
            'OverallStatus; a client that trusts the status code reports failed unsubscribes as ' +
            'successes.',
        paths: [
            'force-app/main/default/classes/SfmcSoapClient.cls',
            'force-app/main/default/classes/SfmcSoapClientTest.cls'
        ]
    },
    {
        id: 'oauth',
        group: 'Integration',
        name: 'OAuth',
        summary: 'Client-credentials flow and a Data Cloud token exchange, both cached in three tiers.',
        detail:
            'Two different OAuth shapes. Marketing Cloud uses client_credentials against an External ' +
            'Credential, so no secret ever appears in source or in a custom setting. Data Cloud needs a ' +
            'token exchange: the core Salesforce token is swapped for a Data Cloud token using the CDP ' +
            'external grant, and the response carries its own instance host. Both cache static → ' +
            'Platform Cache → fresh callout, refreshing inside a safety window so an in-flight callout ' +
            'cannot race the TTL.',
        paths: [
            'force-app/main/default/classes/SfmcAuth.cls',
            'force-app/main/default/classes/DataCloudAuth.cls',
            'force-app/main/default/externalCredentials/SFMC.externalCredential-meta.xml'
        ]
    },
    {
        id: 'etl',
        group: 'Integration',
        name: 'ETL / Informatica pattern',
        summary: 'Staging object plus a promotion batch, the standard iPaaS landing pattern.',
        detail:
            'The shape any ETL tool integrates against. The job bulk-inserts into a staging object with ' +
            'no logic attached, so the load either lands or it does not and it is fast. A batch then ' +
            'validates, resolves match keys and promotes. Two details matter at volume: duplicate rows ' +
            'for the same person are collapsed newest-capture-wins (bulk files routinely contain someone ' +
            'changing their mind twice), and external id beats email as the match key because email ' +
            'addresses get reused between people.',
        paths: [
            'force-app/main/default/classes/ConsentStagingBatch.cls',
            'force-app/main/default/classes/ConsentStagingBatchTest.cls',
            'force-app/main/default/objects/Consent_Staging__c/Consent_Staging__c.object-meta.xml'
        ]
    },
    {
        id: 'data-cloud',
        group: 'Data Cloud',
        name: 'Data Cloud',
        summary: 'Query API v2, DMOs, identity resolution, a Calculated Insight, and the query trace.',
        detail:
            'Consent has to be answered about a person, not about whichever CRM record you opened. This ' +
            'queries the identity graph, the consent DMOs and an engagement Calculated Insight, then ' +
            'resolves consent across every source with most-restrictive-wins. Three targeted queries ' +
            'rather than one wide join, because Data Cloud charges by data processed. The v2 response is ' +
            'column-oriented, so the client zips metadata positions back into named row maps. The Unified ' +
            'Profile tab shows the statements themselves: an unverifiable "3 queries" badge is worth less ' +
            'than the SQL. The statement text is gated behind a custom permission, because it names every ' +
            'DMO and field the org models and a console user has no reason to receive that.',
        paths: [
            'force-app/main/default/classes/DataCloudService.cls',
            'force-app/main/default/classes/DataCloudClient.cls',
            'force-app/main/default/classes/DataCloudServiceTest.cls',
            'force-app/main/default/lwc/dataCloudQueryPanel/dataCloudQueryPanel.js',
            'force-app/main/default/customPermissions/View_Data_Cloud_Diagnostics.customPermission-meta.xml',
            'force-app/main/default/permissionsets/Consent_Center_Developer.permissionset-meta.xml'
        ],
        route: '#/unified'
    },
    {
        id: 'security',
        group: 'Quality',
        name: 'Security',
        summary: 'USER_MODE enforcement, least-privilege permission set, SQL injection defence.',
        detail:
            'The sharp edge here is Data Cloud. Its Query API takes ANSI SQL with no bind variables, so ' +
            'every value is interpolated by hand, and String.escapeSingleQuotes is a SOQL helper that ' +
            'does not cover the backslash escape or comment sequences ANSI SQL honours. DataCloudQuery ' +
            'allowlists literals and identifiers instead of trying to escape dangerous input, and its ' +
            'test class is the security test suite of this repository.',
        paths: [
            'force-app/main/default/classes/DataCloudQuery.cls',
            'force-app/main/default/classes/DataCloudQueryTest.cls',
            'force-app/main/default/permissionsets/Consent_Center_User.permissionset-meta.xml'
        ]
    },
    {
        id: 'bulk',
        group: 'Quality',
        name: 'Large data volumes',
        summary: 'Bulkification asserted by tests that count queries, not just lines covered.',
        detail:
            'Every entry point is collection-based, and the tests assert the thing that actually matters: ' +
            'that a 200-record operation costs the same number of queries as a 1-record one. Selectors ' +
            'carry hard row ceilings so a wide-open search cannot approach the 50,000-row limit, and ' +
            'callout payloads are chunked to what the endpoint will accept before anything is queued.',
        paths: [
            'force-app/main/default/classes/ConsentPreferenceTriggerTest.cls',
            'force-app/main/default/classes/ConsentFlowActionsTest.cls'
        ],
        anchor: 'bulk'
    },
    {
        id: 'testing',
        group: 'Quality',
        name: 'Testing',
        summary: '16 Apex test classes and Jest specs, with mocked callouts and real assertions.',
        detail:
            'Every assertion carries a message explaining what broke and why it matters. The callout ' +
            'mocks route on endpoint so one mock covers a multi-hop integration, and the Data Cloud mock ' +
            'builds the column-oriented response shape from row maps rather than hand-written JSON. ' +
            'Negative paths, boundaries and bulk behaviour are covered, not just the happy path.',
        paths: [
            'force-app/main/default/classes/ConsentServiceTest.cls',
            'force-app/main/default/classes/SfmcCalloutMock.cls',
            'force-app/main/default/classes/DataCloudCalloutMock.cls',
            'force-app/main/default/lwc/contactConsentList/__tests__/contactConsentList.test.js'
        ]
    }
];

/** Capabilities grouped for rendering, preserving declaration order. */
export function groupedCapabilities() {
    const groups = [];
    for (const capability of CAPABILITIES) {
        let group = groups.find((candidate) => candidate.name === capability.group);
        if (!group) {
            group = { name: capability.group, items: [] };
            groups.push(group);
        }
        group.items.push(capability);
    }
    return groups;
}
