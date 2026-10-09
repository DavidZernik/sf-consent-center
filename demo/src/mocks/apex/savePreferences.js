import { store, respond, newId } from './apexRuntime.js';
import { CHANNELS } from '../data/seed.js';

const VALID_CHANNELS = new Set(CHANNELS);

/**
 * Mocks ConsentService.savePreferences.
 *
 * Reproduces the parts of the Apex that the UI can actually observe: channel validation, the
 * no-op skip, the audit trail write, and flipping sync status back to Pending so the sync
 * console visibly picks the change up.
 */
export default function savePreferences({ contactId, changesJson, source } = {}) {
    return respond(() => {
        if (!contactId) {
            throw new Error('A contact is required.');
        }
        if (!changesJson) {
            throw new Error('No preference changes were supplied.');
        }

        const changes = JSON.parse(changesJson);
        for (const change of changes) {
            if (!VALID_CHANNELS.has(change.channel)) {
                throw new Error(`Unsupported channel: ${change.channel}`);
            }
        }

        const now = new Date().toISOString();
        const actor = 'David Zernik';
        const changeSource = source || 'Service Console';

        for (const change of changes) {
            const existing = store.preferences.find(
                (row) => row.contactId === contactId && row.channel === change.channel
            );
            const previous = Boolean(existing && existing.optIn);
            if (existing && previous === change.optIn) {
                continue; // no-op, exactly as the Apex skips it
            }

            store.history.unshift({
                historyId: newId('a0B'),
                contactId,
                channel: change.channel,
                previousValue: existing ? (previous ? 'Opted In' : 'Opted Out') : 'None',
                newValue: change.optIn ? 'Opted In' : 'Opted Out',
                changedByName: actor,
                changeSource,
                changedAt: now
            });

            if (existing) {
                existing.optIn = change.optIn;
                existing.consentSource = changeSource;
                existing.lastChanged = now;
                existing.syncStatus = 'Pending';
            } else {
                const sibling = store.preferences.find((row) => row.contactId === contactId);
                store.preferences.push({
                    preferenceId: newId('a0A'),
                    contactId,
                    contactName: sibling ? sibling.contactName : 'Unknown',
                    email: sibling ? sibling.email : null,
                    channel: change.channel,
                    optIn: change.optIn,
                    consentSource: changeSource,
                    lifecycleStage: sibling ? sibling.lifecycleStage : 'Prospect',
                    lastChanged: now,
                    syncStatus: 'Pending'
                });
            }

            // The Queueable would run out of band; the demo records the queued attempt so the
            // sync console reflects the change immediately.
            store.syncLogs.unshift({
                logId: newId('a0C'),
                preferenceId: existing ? existing.preferenceId : null,
                contactName: existing ? existing.contactName : 'Unknown',
                channel: change.channel,
                status: 'Retrying',
                attempt: 1,
                dataExtensionKey: 'Consent_Preferences',
                statusCode: null,
                errorMessage: 'Queued for delivery.',
                durationMs: null,
                processedAt: now
            });
        }

        const prefs = store.preferences.filter((row) => row.contactId === contactId);
        return {
            contactId,
            contactName: prefs[0] ? prefs[0].contactName : null,
            email: prefs[0] ? prefs[0].email : null,
            lifecycleStage: prefs[0] ? prefs[0].lifecycleStage : null,
            preferences: prefs.map((row) => ({
                preferenceId: row.preferenceId,
                channel: row.channel,
                optIn: row.optIn,
                consentSource: row.consentSource,
                lastChanged: row.lastChanged,
                syncStatus: row.syncStatus
            })),
            history: store.history.filter((entry) => entry.contactId === contactId)
        };
    }, 'savePreferences', { contactId, changesJson, source });
}
