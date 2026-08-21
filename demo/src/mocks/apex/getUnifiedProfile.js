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
        return { ...profile, resolvedConsent: resolveConsent(profile.sourceConsents) };
    });
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

/** Mirrors DataCloudService.describeAgreement — "All 1 sources agree" reads as a bug. */
function describeAgreement(sourceCount, optIn) {
    const position = optIn ? 'opt-in' : 'opt-out';
    return sourceCount === 1
        ? `The only source on record is ${position}.`
        : `All ${sourceCount} sources agree on ${position}.`;
}
