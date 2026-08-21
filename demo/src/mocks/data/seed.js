/**
 * Seed data for the browser demo.
 *
 * Shapes match the Apex DTOs exactly: ConsentService.ConsentSummary, ConsentDetail, SyncLogView
 * and DataCloudService.UnifiedProfile. If a field name here disagrees with the Apex wrapper, the
 * demo is lying about the contract, so this file is the one place worth cross-checking against
 * force-app/main/default/classes/ConsentService.cls.
 */

const CHANNELS = ['Email', 'SMS', 'Push', 'Direct Mail'];

const PEOPLE = [
    ['003Kg000001aA01', 'Dana Reyes', 'dana.reyes@northwind.example', 'Engaged'],
    ['003Kg000001aA02', 'Marcus Bello', 'm.bello@northwind.example', 'Subscriber'],
    ['003Kg000001aA03', 'Priya Raman', 'priya.raman@lakeside.example', 'Engaged'],
    ['003Kg000001aA04', 'Tomás Iglesias', 'tomas.i@lakeside.example', 'Lapsed'],
    ['003Kg000001aA05', 'Aisha Okonkwo', 'aisha.o@brightpath.example', 'Subscriber'],
    ['003Kg000001aA06', 'Jonas Lindqvist', 'jonas.l@brightpath.example', 'Prospect'],
    ['003Kg000001aA07', 'Wen Zhao', 'wen.zhao@northwind.example', 'Engaged'],
    ['003Kg000001aA08', 'Rosa Delgado', 'rosa.d@lakeside.example', 'Unsubscribed'],
    ['003Kg000001aA09', 'Ade Fashola', 'ade.f@brightpath.example', 'Subscriber'],
    ['003Kg000001aA10', 'Hannah Weiss', 'h.weiss@northwind.example', 'Lapsed'],
    ['003Kg000001aA11', 'Diego Moreau', 'd.moreau@lakeside.example', 'Prospect'],
    ['003Kg000001aA12', 'Sofia Kalu', 'sofia.kalu@brightpath.example', 'Engaged']
];

const SOURCES = ['Preference Centre', 'Service Console', 'Mobile App', 'Bulk Load', 'Support Case', 'REST API'];

/** Deterministic pseudo-random so the demo looks identical on every load. */
function seededRandom(seed) {
    let value = seed;
    return () => {
        value = (value * 1103515245 + 12345) % 2147483648;
        return value / 2147483648;
    };
}

const random = seededRandom(20260821);

function hoursAgo(hours) {
    return new Date(Date.parse('2026-08-21T14:30:00Z') - hours * 3600 * 1000).toISOString();
}

function buildPreferences() {
    const rows = [];
    PEOPLE.forEach(([contactId, contactName, email, stage], personIndex) => {
        CHANNELS.forEach((channel, channelIndex) => {
            // Draw each attribute independently. Deriving several fields from one roll
            // correlates them, which produced a table where every recently-changed row was also
            // an opt-out, data that looks broken rather than realistic.
            const consentRoll = random();
            const recencyRoll = random();
            const sourceRoll = random();
            const syncRoll = random();

            // Unsubscribed contacts are opted out everywhere. The data has to be internally
            // consistent or the lifecycle path contradicts the toggles.
            const optIn = stage === 'Unsubscribed' ? false : consentRoll > 0.4;
            const syncStatus = syncRoll > 0.88 ? 'Failed' : syncRoll > 0.76 ? 'Pending' : 'Synced';

            rows.push({
                preferenceId: `a0AKg00000${String(personIndex * 4 + channelIndex).padStart(5, '0')}`,
                contactId,
                contactName,
                email,
                channel,
                optIn,
                consentSource: SOURCES[Math.floor(sourceRoll * SOURCES.length) % SOURCES.length],
                lifecycleStage: stage,
                lastChanged: hoursAgo(Math.floor(recencyRoll * 800) + channelIndex),
                syncStatus
            });
        });
    });
    return rows;
}

const PREFERENCES = buildPreferences();

const HISTORY = [
    ['003Kg000001aA01', 'Email', 'Opted Out', 'Opted In', 'Dana Reyes', 'Preference Centre', hoursAgo(31)],
    ['003Kg000001aA01', 'SMS', 'None', 'Opted In', 'Integration User', 'Mobile App', hoursAgo(204)],
    ['003Kg000001aA01', 'Direct Mail', 'Opted In', 'Opted Out', 'A. Whitfield', 'Service Console', hoursAgo(410)],
    ['003Kg000001aA02', 'Email', 'None', 'Opted In', 'Integration User', 'Bulk Load', hoursAgo(96)],
    ['003Kg000001aA03', 'Push', 'Opted Out', 'Opted In', 'Priya Raman', 'Mobile App', hoursAgo(12)],
    ['003Kg000001aA04', 'Email', 'Opted In', 'Opted Out', 'Support Agent', 'Support Case', hoursAgo(58)],
    ['003Kg000001aA08', 'Email', 'Opted In', 'Opted Out', 'Rosa Delgado', 'Preference Centre', hoursAgo(6)],
    ['003Kg000001aA08', 'SMS', 'Opted In', 'Opted Out', 'Rosa Delgado', 'Preference Centre', hoursAgo(6)],
    ['003Kg000001aA08', 'Push', 'Opted In', 'Opted Out', 'Rosa Delgado', 'Preference Centre', hoursAgo(6)]
].map(([contactId, channel, previousValue, newValue, changedByName, changeSource, changedAt], index) => ({
    historyId: `a0BKg00000${String(index).padStart(5, '0')}`,
    contactId,
    channel,
    previousValue,
    newValue,
    changedByName,
    changeSource,
    changedAt
}));

function buildSyncLogs() {
    const logs = [];
    let index = 0;
    for (const pref of PREFERENCES) {
        if (pref.syncStatus === 'Synced' && random() > 0.35) continue;
        const failed = pref.syncStatus === 'Failed';
        const retrying = pref.syncStatus === 'Pending';
        logs.push({
            logId: `a0CKg00000${String(index++).padStart(5, '0')}`,
            preferenceId: pref.preferenceId,
            contactName: pref.contactName,
            channel: pref.channel,
            status: failed ? 'Failed' : retrying ? 'Retrying' : 'Success',
            attempt: failed ? 4 : retrying ? 2 : 1,
            dataExtensionKey: 'Consent_Preferences',
            statusCode: failed ? 400 : retrying ? 500 : 202,
            errorMessage: failed
                ? 'Invalid SubscriberKey: no matching subscriber in the All Subscribers list.'
                : retrying
                  ? 'Internal Server Error'
                  : null,
            durationMs: Math.floor(random() * 900) + 90,
            processedAt: hoursAgo(Math.floor(random() * 72))
        });
    }
    return logs.sort((a, b) => (a.processedAt < b.processedAt ? 1 : -1));
}

const SYNC_LOGS = buildSyncLogs();

/**
 * Unified profiles keyed by CRM contact id.
 *
 * Dana Reyes is deliberately the conflicted case: three source records, one of which carries an
 * opt-out, so the resolved answer disagrees with what the CRM record alone would tell you.
 */
const UNIFIED_PROFILES = {
    '003Kg000001aA01': {
        unifiedId: 'UNI-4471-0A9C',
        name: 'Dana Reyes',
        primaryEmail: 'dana.reyes@northwind.example',
        queryDurationMs: 412,
        sources: [
            {
                sourceRecordId: '003Kg000001aA01',
                sourceSystem: 'Salesforce CRM',
                email: 'dana.reyes@northwind.example',
                matchConfidence: 1,
                lastModified: hoursAgo(31)
            },
            {
                sourceRecordId: 'POS-88213',
                sourceSystem: 'Point of Sale',
                email: 'd.reyes@northwind.example',
                matchConfidence: 0.94,
                lastModified: hoursAgo(190)
            },
            {
                sourceRecordId: 'LOY-00519',
                sourceSystem: 'Loyalty Platform',
                email: 'dana.reyes@northwind.example',
                matchConfidence: 0.88,
                lastModified: hoursAgo(720)
            }
        ],
        sourceConsents: [
            { sourceRecordId: '003Kg000001aA01', sourceSystem: 'Salesforce CRM', channel: 'Email', optIn: true, capturedAt: hoursAgo(31) },
            { sourceRecordId: 'POS-88213', sourceSystem: 'Point of Sale', channel: 'Email', optIn: false, capturedAt: hoursAgo(190) },
            { sourceRecordId: 'LOY-00519', sourceSystem: 'Loyalty Platform', channel: 'Email', optIn: true, capturedAt: hoursAgo(720) },
            { sourceRecordId: '003Kg000001aA01', sourceSystem: 'Salesforce CRM', channel: 'SMS', optIn: true, capturedAt: hoursAgo(204) },
            { sourceRecordId: 'LOY-00519', sourceSystem: 'Loyalty Platform', channel: 'SMS', optIn: true, capturedAt: hoursAgo(720) },
            { sourceRecordId: 'POS-88213', sourceSystem: 'Point of Sale', channel: 'Direct Mail', optIn: false, capturedAt: hoursAgo(190) }
        ],
        engagement: {
            score: 82.4,
            band: 'Highly engaged',
            lastEngagementAt: hoursAgo(19),
            emailOpens90d: 27,
            clicks90d: 9
        }
    },
    '003Kg000001aA04': {
        unifiedId: 'UNI-7732-2B41',
        name: 'Tomás Iglesias',
        primaryEmail: 'tomas.i@lakeside.example',
        queryDurationMs: 288,
        sources: [
            {
                sourceRecordId: '003Kg000001aA04',
                sourceSystem: 'Salesforce CRM',
                email: 'tomas.i@lakeside.example',
                matchConfidence: 1,
                lastModified: hoursAgo(58)
            },
            {
                sourceRecordId: 'WEB-41192',
                sourceSystem: 'Web Forms',
                email: 'tomas.i@lakeside.example',
                matchConfidence: 0.97,
                lastModified: hoursAgo(300)
            }
        ],
        sourceConsents: [
            { sourceRecordId: '003Kg000001aA04', sourceSystem: 'Salesforce CRM', channel: 'Email', optIn: false, capturedAt: hoursAgo(58) },
            { sourceRecordId: 'WEB-41192', sourceSystem: 'Web Forms', channel: 'Email', optIn: false, capturedAt: hoursAgo(300) },
            { sourceRecordId: 'WEB-41192', sourceSystem: 'Web Forms', channel: 'Push', optIn: true, capturedAt: hoursAgo(300) }
        ],
        engagement: {
            score: 21.6,
            band: 'At risk',
            lastEngagementAt: hoursAgo(640),
            emailOpens90d: 3,
            clicks90d: 0
        }
    }
};

export { CHANNELS, PEOPLE, PREFERENCES, HISTORY, SYNC_LOGS, UNIFIED_PROFILES };
