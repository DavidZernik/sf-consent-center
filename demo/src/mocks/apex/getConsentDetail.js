import { store, respond, apexError } from './apexRuntime.js';
import { CHANNELS } from '../data/seed.js';

/** Mocks ConsentService.getConsentDetail: preferences plus audit trail for one contact. */
export default function getConsentDetail({ contactId } = {}) {
    return respond(() => {
        if (!contactId) {
            throw new Error('A contact is required.');
        }
        const prefs = store.preferences.filter((row) => row.contactId === contactId);
        if (prefs.length === 0) {
            throw new Error('No consent records found for that contact.');
        }
        return {
            contactId,
            contactName: prefs[0].contactName,
            email: prefs[0].email,
            lifecycleStage: prefs[0].lifecycleStage,
            preferences: CHANNELS.map((channel) => {
                const match = prefs.find((row) => row.channel === channel);
                return match
                    ? {
                          preferenceId: match.preferenceId,
                          channel,
                          optIn: match.optIn,
                          consentSource: match.consentSource,
                          lastChanged: match.lastChanged,
                          syncStatus: match.syncStatus
                      }
                    : null;
            }).filter(Boolean),
            history: store.history
                .filter((entry) => entry.contactId === contactId)
                .sort((a, b) => (a.changedAt < b.changedAt ? 1 : -1))
        };
    }, 'getConsentDetail', { contactId });
}

export { apexError };
