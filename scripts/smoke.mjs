/**
 * Pre-build smoke check for the demo data layer.
 *
 * Motivated by a real failure: a stale variable reference in seed.js threw at module scope. The
 * bundle built without complaint (Rollup has no reason to object to valid syntax) and the app
 * then died on boot with a blank page. A green build that ships a blank page is the worst kind
 * of green, so the mocks are imported and exercised here before anything is bundled.
 */
import assert from 'node:assert/strict';

const failures = [];

async function check(name, fn) {
    try {
        await fn();
        console.log(`  ok  ${name}`);
    } catch (error) {
        failures.push({ name, message: error.message });
        console.error(`  FAIL  ${name}: ${error.message}`);
    }
}

const seed = await import('../demo/src/mocks/data/seed.js');
const { seedStore } = await import('../demo/src/mocks/apex/seedStore.js');
seedStore();

const getConsentSummaries = (await import('../demo/src/mocks/apex/getConsentSummaries.js')).default;
const getConsentDetail = (await import('../demo/src/mocks/apex/getConsentDetail.js')).default;
const savePreferences = (await import('../demo/src/mocks/apex/savePreferences.js')).default;
const getSyncLogs = (await import('../demo/src/mocks/apex/getSyncLogs.js')).default;
const retrySync = (await import('../demo/src/mocks/apex/retrySync.js')).default;
const getUnifiedProfile = (await import('../demo/src/mocks/apex/getUnifiedProfile.js')).default;

console.log('demo data layer:');

await check('seed produces preferences across all channels', () => {
    assert.ok(seed.PREFERENCES.length > 0, 'no preferences generated');
    const channels = new Set(seed.PREFERENCES.map((row) => row.channel));
    assert.equal(channels.size, 4, `expected 4 channels, got ${channels.size}`);
});

await check('seed is not degenerate on consent', () => {
    const optedIn = seed.PREFERENCES.filter((row) => row.optIn).length;
    const optedOut = seed.PREFERENCES.length - optedIn;
    // A table that is all one value looks broken to a first-time viewer even when it is correct.
    assert.ok(optedIn >= 5, `only ${optedIn} opted-in rows`);
    assert.ok(optedOut >= 5, `only ${optedOut} opted-out rows`);
});

await check('consent is uncorrelated with recency', () => {
    // The specific regression this guards: deriving optIn and lastChanged from one random draw
    // made every recently-changed row an opt-out.
    const sorted = [...seed.PREFERENCES].sort((a, b) => (a.lastChanged < b.lastChanged ? 1 : -1));
    const topTwelve = sorted.slice(0, 12);
    const optedIn = topTwelve.filter((row) => row.optIn).length;
    assert.ok(
        optedIn > 0 && optedIn < 12,
        `the 12 most recent rows are all the same consent value (${optedIn} opted in)`
    );
});

await check('unsubscribed contacts are opted out everywhere', () => {
    const unsubscribed = seed.PREFERENCES.filter((row) => row.lifecycleStage === 'Unsubscribed');
    assert.ok(unsubscribed.length > 0, 'fixture has no unsubscribed contact');
    assert.ok(
        unsubscribed.every((row) => row.optIn === false),
        'an Unsubscribed contact is opted in somewhere, which contradicts the lifecycle path'
    );
});

await check('getConsentSummaries returns rows and honours the channel filter', async () => {
    const all = await getConsentSummaries({});
    assert.ok(all.length > 0, 'no summaries returned');
    const sms = await getConsentSummaries({ channel: 'SMS' });
    assert.ok(sms.length > 0, 'no SMS rows');
    assert.ok(sms.every((row) => row.channel === 'SMS'), 'channel filter leaked another channel');
});

await check('getConsentSummaries search matches on name and email', async () => {
    const byName = await getConsentSummaries({ searchTerm: 'Dana' });
    assert.ok(byName.length > 0, 'name search returned nothing');
    const byEmail = await getConsentSummaries({ searchTerm: 'northwind' });
    assert.ok(byEmail.length > 0, 'email search returned nothing');
});

await check('getConsentDetail returns every channel plus history', async () => {
    const detail = await getConsentDetail({ contactId: seed.PEOPLE[0][0] });
    assert.ok(detail.contactName, 'no contact name');
    assert.equal(detail.preferences.length, 4, 'expected all four channels');
    assert.ok(Array.isArray(detail.history), 'history missing');
});

await check('savePreferences applies a change and writes the audit trail', async () => {
    const contactId = seed.PEOPLE[1][0];
    const before = await getConsentDetail({ contactId });
    const target = before.preferences.find((p) => p.channel === 'Email');
    const detail = await savePreferences({
        contactId,
        changesJson: JSON.stringify([{ channel: 'Email', optIn: !target.optIn }]),
        source: 'Smoke Test'
    });
    const after = detail.preferences.find((p) => p.channel === 'Email');
    assert.equal(after.optIn, !target.optIn, 'the change was not applied');
    assert.ok(detail.history.length > 0, 'no audit row written');
});

await check('savePreferences rejects an unsupported channel', async () => {
    await assert.rejects(
        () => savePreferences({
            contactId: seed.PEOPLE[0][0],
            changesJson: JSON.stringify([{ channel: 'Carrier Pigeon', optIn: true }]),
            source: 'Smoke Test'
        }),
        (error) => String(error?.body?.message ?? '').includes('Carrier Pigeon'),
        'expected a rejection naming the bad channel'
    );
});

await check('getSyncLogs filters by status', async () => {
    const all = await getSyncLogs({ status: 'All' });
    assert.ok(all.length > 0, 'no sync logs');
    const failed = await getSyncLogs({ status: 'Failed' });
    assert.ok(failed.every((row) => row.status === 'Failed'), 'status filter leaked');
});

await check('retrySync handles an empty selection', async () => {
    const result = await retrySync({ logIds: [] });
    assert.equal(result.queued, 0);
    assert.equal(result.message, 'Nothing selected to retry.');
});

await check('getUnifiedProfile resolves consent most-restrictive-wins', async () => {
    const profile = await getUnifiedProfile({ contactId: '003Kg000001aA01' });
    assert.ok(profile.sources.length >= 2, 'expected a multi-source identity graph');
    const email = profile.resolvedConsent.find((channel) => channel.channel === 'Email');
    assert.ok(email, 'no resolved Email channel');
    // The fixture has one opt-out among opt-ins, so the resolved answer must be opted out.
    assert.equal(email.optIn, false, 'a single source opt-out failed to win');
    assert.equal(email.isConflicted, true, 'the disagreement was not flagged');
});

await check('getUnifiedProfile explains a missing profile', async () => {
    await assert.rejects(
        () => getUnifiedProfile({ contactId: '003Kg000001aZZZ' }),
        (error) => String(error?.body?.message ?? '').includes('Identity Resolution'),
        'expected a message pointing at Identity Resolution'
    );
});

if (failures.length > 0) {
    console.error(`\n${failures.length} smoke check(s) failed.\n`);
    process.exit(1);
}
console.log(`\nAll demo data checks passed.\n`);
