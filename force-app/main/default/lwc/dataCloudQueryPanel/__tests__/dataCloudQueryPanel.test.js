import { createElement } from 'lwc';
import DataCloudQueryPanel from 'c/dataCloudQueryPanel';

const QUERIES = [
    {
        purpose: 'Identity graph',
        dmo: 'IndividualIdentityLink__dlm',
        rowCount: 3,
        durationMs: 185,
        sql: 'SELECT link.UnifiedRecordId__c FROM IndividualIdentityLink__dlm link'
    },
    {
        purpose: 'Engagement Calculated Insight',
        dmo: 'Engagement_Score__cio',
        rowCount: 1,
        durationMs: 63,
        sql: 'SELECT Engagement_Score__c FROM Engagement_Score__cio'
    }
];

function render(props = {}) {
    const el = createElement('c-data-cloud-query-panel', { is: DataCloudQueryPanel });
    Object.assign(el, props);
    document.body.appendChild(el);
    return el;
}

function expand(el) {
    el.shadowRoot.querySelector('button').click();
    return Promise.resolve();
}

describe('c-data-cloud-query-panel', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('renders nothing when no queries ran', () => {
        expect(render({ queries: [] }).shadowRoot.querySelector('.panel')).toBeNull();
    });

    it('survives a null queries payload', () => {
        // Apex returns null for an empty list often enough that assuming an array is a bug.
        expect(render({ queries: null }).shadowRoot.querySelector('.panel')).toBeNull();
    });

    it('summarises count, rows and time without being expanded', () => {
        const el = render({ queries: QUERIES, totalDurationMs: 248 });
        expect(el.shadowRoot.textContent).toContain('2 queries · 4 rows · 248 ms');
        expect(el.shadowRoot.querySelector('.sql')).toBeNull();
    });

    it('shows each statement and the DMO it hits once expanded', () => {
        const el = render({ queries: QUERIES, totalDurationMs: 248 });
        return expand(el).then(() => {
            const sql = [...el.shadowRoot.querySelectorAll('.sql')].map((n) => n.textContent);
            expect(sql).toHaveLength(2);
            expect(sql[0]).toContain('IndividualIdentityLink__dlm');
            const dmos = [...el.shadowRoot.querySelectorAll('.dmo')].map((n) => n.textContent);
            expect(dmos).toEqual(['IndividualIdentityLink__dlm', 'Engagement_Score__cio']);
        });
    });

    it('explains a withheld statement rather than rendering an empty box', () => {
        // Apex returns sql: null unless the user holds View_Data_Cloud_Diagnostics.
        const el = render({ queries: [{ ...QUERIES[0], sql: null }], totalDurationMs: 185 });
        return expand(el).then(() => {
            expect(el.shadowRoot.querySelector('.sql')).toBeNull();
            expect(el.shadowRoot.textContent).toContain('View_Data_Cloud_Diagnostics');
        });
    });

    it('says "1 row", not "1 rows"', () => {
        const el = render({ queries: [{ ...QUERIES[1] }], totalDurationMs: 63 });
        return expand(el).then(() => {
            expect(el.shadowRoot.textContent).toContain('1 row ·');
            expect(el.shadowRoot.textContent).not.toContain('1 rows');
        });
    });

    it('falls back to a dash when a row count or timing is missing', () => {
        const el = render({ queries: [{ purpose: 'x', dmo: 'y__dlm', sql: 'SELECT 1' }] });
        return expand(el).then(() => {
            expect(el.shadowRoot.textContent).toContain('- rows');
        });
    });
});
