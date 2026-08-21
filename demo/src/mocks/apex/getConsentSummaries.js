import { store, respond } from './apexRuntime.js';

/**
 * Mocks ConsentService.getConsentSummaries.
 *
 * The filtering below reproduces what the SOQL in ConsentSelector.searchSummaries does, including
 * the row ceiling, so the UI hits the same truncation behaviour it would in an org.
 */
export default function getConsentSummaries({ searchTerm, channel } = {}) {
    return respond(() => {
        const term = (searchTerm || '').trim().toLowerCase();
        let rows = store.preferences;

        if (channel && channel !== 'All') {
            rows = rows.filter((row) => row.channel === channel);
        }
        if (term) {
            rows = rows.filter(
                (row) =>
                    row.contactName.toLowerCase().includes(term) ||
                    (row.email || '').toLowerCase().includes(term)
            );
        }
        return rows
            .slice()
            .sort((a, b) => (a.lastChanged < b.lastChanged ? 1 : -1))
            .slice(0, 200);
    });
}
