import { store, respond } from './apexRuntime.js';

/**
 * Mocks DataCloudService.getUnifiedProfile.
 *
 * The consent resolution below is a direct port of DataCloudService.resolveConsent, including
 * most-restrictive-wins and the conflict flag. Reimplementing rather than hardcoding the answer
 * keeps the demo honest when the seed data changes.
 */
export default function getUnifiedProfile({ contactId } = {}) {
    return respond(() => {
        if (!contactId) {
            throw new Error('A contact is required.');
        }
        const profile = store.unifiedProfiles[contactId];
        if (!profile) {
            throw new Error(
                'No unified profile found for this contact. Identity Resolution may not have run yet.'
            );
        }
        return {
            ...profile,
            resolvedConsent: resolveConsent(profile.sourceConsents),
            queries: buildQueryTrace(contactId, profile)
        };
    });
}

/**
 * The DMO and Calculated Insight names DataCloudService queries.
 *
 * Duplicated here rather than imported, because Apex constants cannot be imported into a
 * browser bundle. scripts/smoke.mjs asserts every name below still appears in
 * DataCloudService.cls, so the demo cannot drift into showing SQL the Apex does not run.
 */
export const DMO = {
    identityLink: 'IndividualIdentityLink__dlm',
    unifiedIndividual: 'UnifiedIndividual__dlm',
    email: 'ssot__ContactPointEmail__dlm',
    consent: 'ssot__ContactPointConsent__dlm',
    engagementCi: 'Engagement_Score__cio'
};

/**
 * Rebuilds the query trace DataCloudService returns.
 *
 * The statements mirror the ones the Apex composes, including the sub-select that finds the
 * unified id from a CRM record id. Timings are apportioned across the three so they add up to
 * the profile's total rather than being three unrelated numbers.
 */
function buildQueryTrace(contactId, profile) {
    const total = profile.queryDurationMs || 0;
    const linkMs = Math.round(total * 0.45);
    const consentMs = Math.round(total * 0.35);
    const sourceIds = profile.sources.map((s) => `'${s.sourceRecordId}'`).join(', ');

    return [
        {
            purpose: 'Identity graph',
            dmo: DMO.identityLink,
            rowCount: profile.sources.length,
            durationMs: linkMs,
            sql:
                `SELECT link.UnifiedRecordId__c, link.SourceRecordId__c, link.SourceSystemName__c,\n` +
                `       link.MatchConfidence__c, ui.ssot__FirstName__c, ui.ssot__LastName__c,\n` +
                `       email.ssot__EmailAddress__c, link.ssot__LastModifiedDate__c\n` +
                `FROM ${DMO.identityLink} link\n` +
                `JOIN ${DMO.unifiedIndividual} ui ON link.UnifiedRecordId__c = ui.ssot__Id__c\n` +
                `LEFT JOIN ${DMO.email} email ON email.ssot__PartyId__c = ui.ssot__Id__c\n` +
                `WHERE link.UnifiedRecordId__c IN (\n` +
                `  SELECT UnifiedRecordId__c FROM ${DMO.identityLink}\n` +
                `  WHERE SourceRecordId__c = '${contactId}'\n` +
                `) LIMIT 200`
        },
        {
            purpose: 'Consent by contact point',
            dmo: DMO.consent,
            rowCount: profile.sourceConsents.length,
            durationMs: consentMs,
            sql:
                `SELECT ssot__PartyIdentificationId__c, ssot__ContactPointType__c,\n` +
                `       ssot__ConsentStatus__c, ssot__EffectiveFromDate__c, ssot__DataSourceName__c\n` +
                `FROM ${DMO.consent}\n` +
                `WHERE ssot__PartyIdentificationId__c IN (${sourceIds})\n` +
                `LIMIT 1000`
        },
        {
            purpose: 'Engagement Calculated Insight',
            dmo: DMO.engagementCi,
            rowCount: profile.engagement ? 1 : 0,
            durationMs: total - linkMs - consentMs,
            sql:
                `SELECT Engagement_Score__c, Last_Engagement_Date__c, Email_Opens_90d__c, Clicks_90d__c\n` +
                `FROM ${DMO.engagementCi}\n` +
                `WHERE UnifiedIndividualId__c = '${profile.unifiedId}'\n` +
                `LIMIT 1`
        }
    ];
}

function resolveConsent(sourceConsents) {
    const byChannel = new Map();
    for (const consent of sourceConsents) {
        if (!byChannel.has(consent.channel)) {
            byChannel.set(consent.channel, []);
        }
        byChannel.get(consent.channel).push(consent);
    }

    const resolved = [];
    for (const [channel, entries] of byChannel) {
        const optedIn = entries.filter((entry) => entry.optIn).length;
        const optedOut = entries.length - optedIn;
        const isConflicted = optedIn > 0 && optedOut > 0;
        const optIn = optedOut === 0;

        resolved.push({
            channel,
            optIn,
            isConflicted,
            sourcesTotal: entries.length,
            sourcesAgreeing: optIn ? optedIn : optedOut,
            reason: isConflicted
                ? `${optedOut} of ${entries.length} sources recorded an opt-out. Most restrictive wins, so the unified profile is opted out.`
                : describeAgreement(entries.length, optIn)
        });
    }
    return resolved;
}

/** Mirrors DataCloudService.describeAgreement. "All 1 sources agree" reads as a bug. */
function describeAgreement(sourceCount, optIn) {
    const position = optIn ? 'opt-in' : 'opt-out';
    return sourceCount === 1
        ? `The only source on record is ${position}.`
        : `All ${sourceCount} sources agree on ${position}.`;
}
