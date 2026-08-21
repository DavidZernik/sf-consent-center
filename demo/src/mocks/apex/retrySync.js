import { store, respond } from './apexRuntime.js';

/**
 * Mocks ConsentService.retrySync.
 *
 * Keeps the skip rule that matters: a log whose preference already synced is not re-sent, so a
 * console left open overnight cannot cause duplicate Data Extension writes.
 */
export default function retrySync({ logIds } = {}) {
    return respond(() => {
        if (!logIds || logIds.length === 0) {
            return { queued: 0, skipped: 0, message: 'Nothing selected to retry.' };
        }

        let queued = 0;
        let skipped = 0;
        const now = new Date().toISOString();

        for (const logId of logIds) {
            const log = store.syncLogs.find((row) => row.logId === logId);
            if (!log) {
                skipped++;
                continue;
            }
            const pref = store.preferences.find((row) => row.preferenceId === log.preferenceId);
            if (!pref || pref.syncStatus === 'Synced') {
                skipped++;
                continue;
            }
            // The retry succeeds in the demo so the state visibly settles.
            pref.syncStatus = 'Synced';
            log.status = 'Success';
            log.attempt = (log.attempt || 1) + 1;
            log.statusCode = 202;
            log.errorMessage = null;
            log.durationMs = 140 + Math.floor(Math.random() * 200);
            log.processedAt = now;
            queued++;
        }
        return { queued, skipped, message: `${queued} queued, ${skipped} skipped.` };
    });
}
