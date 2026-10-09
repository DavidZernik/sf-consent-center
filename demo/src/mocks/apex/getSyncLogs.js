import { store, respond } from './apexRuntime.js';

/** Mocks ConsentService.getSyncLogs. */
export default function getSyncLogs({ status } = {}) {
    return respond(() => {
        const rows = !status || status === 'All'
            ? store.syncLogs
            : store.syncLogs.filter((row) => row.status === status);
        return rows.slice(0, 100);
    }, 'getSyncLogs', { status });
}
