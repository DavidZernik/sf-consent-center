import { LightningElement, api } from 'lwc';

/**
 * Read-only audit trail, rendered as an SLDS activity timeline.
 *
 * Takes its data as a property rather than querying Apex itself: the parent already loaded
 * the history as part of getConsentDetail, and a second round trip for the same data would be
 * waste the user pays for.
 */
export default class ConsentHistoryTimeline extends LightningElement {
    _entries = [];

    @api
    get entries() {
        return this._entries;
    }
    set entries(value) {
        this._entries = Array.isArray(value) ? value : [];
    }

    get hasEntries() {
        return this._entries.length > 0;
    }

    get decoratedEntries() {
        return this._entries.map((entry) => ({
            ...entry,
            key: entry.historyId,
            isOptIn: entry.newValue === 'Opted In',
            iconName: entry.newValue === 'Opted In' ? 'utility:check' : 'utility:close',
            iconVariant: entry.newValue === 'Opted In' ? 'success' : 'error',
            summary: `${entry.channel}: ${entry.previousValue} → ${entry.newValue}`
        }));
    }
}
