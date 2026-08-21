import { store } from './apexRuntime.js';
import { PREFERENCES, HISTORY, SYNC_LOGS, UNIFIED_PROFILES } from '../data/seed.js';

/** Loads the fixture into the mutable store. Called once from the demo entry point. */
export function seedStore() {
    store.preferences = JSON.parse(JSON.stringify(PREFERENCES));
    store.history = JSON.parse(JSON.stringify(HISTORY));
    store.syncLogs = JSON.parse(JSON.stringify(SYNC_LOGS));
    store.unifiedProfiles = JSON.parse(JSON.stringify(UNIFIED_PROFILES));
}
