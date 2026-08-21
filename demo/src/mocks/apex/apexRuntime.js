/**
 * Shared runtime for the mocked Apex methods.
 *
 * Every mock resolves through here so the demo behaves like a real Lightning app rather than a
 * static page: calls are asynchronous, they take a plausible amount of time, and errors surface
 * in the same { body: { message } } shape the real Apex boundary produces. Components therefore
 * exercise their loading and error branches for real.
 */

/** Mutable in-memory store. Seeded once, then mutated by the write paths. */
export const store = {
    preferences: [],
    history: [],
    syncLogs: [],
    unifiedProfiles: {}
};

let nextId = 90000;

export function newId(prefix) {
    nextId += 1;
    return `${prefix}${String(nextId).padStart(12, '0')}`;
}

/** Latency band, in ms, roughly matching a real cacheable Apex round trip. */
const LATENCY = { min: 180, max: 420 };

function latency() {
    return LATENCY.min + Math.random() * (LATENCY.max - LATENCY.min);
}

/** Resolves like a real imperative Apex call: async, after a realistic delay. */
export function respond(producer) {
    return new Promise((resolve, reject) => {
        setTimeout(() => {
            try {
                // Structured-clone the payload so a component mutating its own copy cannot
                // corrupt the store — the real wire boundary serialises, so this matches.
                resolve(JSON.parse(JSON.stringify(producer())));
            } catch (error) {
                reject(apexError(error.message));
            }
        }, latency());
    });
}

/** Mirrors the shape an AuraHandledException arrives in on the client. */
export function apexError(message) {
    return { body: { message }, status: 400, statusText: 'Bad Request' };
}

export function deepClone(value) {
    return JSON.parse(JSON.stringify(value));
}
