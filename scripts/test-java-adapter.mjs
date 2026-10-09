import assert from 'node:assert/strict';
import { isJavaBackend, javaRequest } from '../demo/src/mocks/apex/javaBackend.js';

assert.equal(isJavaBackend(), false);
globalThis.window = { location: { search: '?backend=java' } };
assert.equal(isJavaBackend(), true);
const calls = [];
globalThis.fetch = async (url, options) => {
    calls.push({ url, options });
    return { ok: true, json: async () => ({ contactId: '003-demo' }) };
};
await javaRequest('getConsentSummaries', { searchTerm: 'A&B', channel: 'Direct Mail' });
assert.equal(calls[0].url, '/api/consents?searchTerm=A%26B&channel=Direct+Mail');
await javaRequest('savePreferences', { contactId: '003-demo', changesJson: '[]', source: 'Test' });
assert.equal(calls[1].options.method, 'POST');
assert.equal(JSON.parse(calls[1].options.body).contactId, '003-demo');
globalThis.fetch = async () => ({ ok: false, status: 400, json: async () => ({ body: { message: 'Invalid channel' } }) });
await assert.rejects(javaRequest('retrySync', { logIds: [] }), e => e.body.message === 'Invalid channel' && e.status === 400);
globalThis.fetch = async () => { throw new Error('offline'); };
await assert.rejects(javaRequest('getSyncLogs'), e => e.body.message.includes('unavailable'));
// Opting into Java mode must never silently fall back to browser fixtures.
const { respond } = await import('../demo/src/mocks/apex/apexRuntime.js');
await assert.rejects(respond(() => 'fixture', 'getSyncLogs', {}), e => e.body.message.includes('unavailable'));
console.log('Java adapter: routing, encoding, writes, error contracts, and no silent fallback verified.');
