import { createElement } from 'lwc';
import ContactConsentList from 'c/contactConsentList';
import getConsentSummaries from '@salesforce/apex/ConsentService.getConsentSummaries';

jest.mock(
    '@salesforce/apex/ConsentService.getConsentSummaries',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const SUMMARY = {
    preferenceId: 'a0A1',
    contactId: '0031',
    contactName: 'Dana Reyes',
    email: 'dana@example.invalid',
    channel: 'Email',
    optIn: true,
    consentSource: 'Preference Centre',
    lifecycleStage: 'Engaged',
    lastChanged: '2026-08-20T10:00:00.000Z',
    syncStatus: 'Synced'
};

function mount() {
    const element = createElement('c-contact-consent-list', { is: ContactConsentList });
    document.body.appendChild(element);
    return element;
}

/** Lets the component's promise chain and the resulting re-render settle. */
async function settle() {
    await Promise.resolve();
    await Promise.resolve();
}

describe('c-contact-consent-list', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
        jest.useRealTimers();
    });

    it('loads rows on connect and renders the datatable', async () => {
        getConsentSummaries.mockResolvedValue([SUMMARY]);
        const element = mount();
        await settle();

        const table = element.shadowRoot.querySelector('lightning-datatable');
        expect(table).not.toBeNull();
        expect(table.data).toHaveLength(1);
        expect(table.data[0].contactName).toBe('Dana Reyes');
    });

    it('derives a sync status class so failures read as failures', async () => {
        getConsentSummaries.mockResolvedValue([
            { ...SUMMARY, syncStatus: 'Failed' },
            { ...SUMMARY, preferenceId: 'a0A2', syncStatus: 'Pending' },
            { ...SUMMARY, preferenceId: 'a0A3', syncStatus: 'Synced' }
        ]);
        const element = mount();
        await settle();

        const rows = element.shadowRoot.querySelector('lightning-datatable').data;
        expect(rows[0].syncStatusClass).toBe('slds-text-color_error');
        expect(rows[1].syncStatusClass).toBe('slds-text-color_weak');
        expect(rows[2].syncStatusClass).toBe('slds-text-color_success');
    });

    it('states consent in words rather than relying on a blank cell', async () => {
        getConsentSummaries.mockResolvedValue([
            { ...SUMMARY, optIn: true },
            { ...SUMMARY, preferenceId: 'a0A2', optIn: false }
        ]);
        const element = mount();
        await settle();

        const rows = element.shadowRoot.querySelector('lightning-datatable').data;
        expect(rows[0].consentLabel).toBe('Opted in');
        // The important half: an opt-out must render text, not an empty cell that reads the
        // same as "no consent record exists".
        expect(rows[1].consentLabel).toBe('Opted out');
        expect(rows[1].consentClass).toContain('slds-text-color_error');
    });

    it('debounces search so a burst of keystrokes makes one Apex call', async () => {
        jest.useFakeTimers();
        getConsentSummaries.mockResolvedValue([]);
        const element = mount();
        await settle();
        getConsentSummaries.mockClear();

        const input = element.shadowRoot.querySelector('lightning-input');
        for (const value of ['d', 'da', 'dan', 'dana']) {
            input.value = value;
            input.dispatchEvent(new CustomEvent('change', { target: { value } }));
        }

        expect(getConsentSummaries).not.toHaveBeenCalled();
        jest.advanceTimersByTime(400);
        expect(getConsentSummaries).toHaveBeenCalledTimes(1);
    });

    it('passes the channel filter through to Apex', async () => {
        getConsentSummaries.mockResolvedValue([]);
        const element = mount();
        await settle();
        getConsentSummaries.mockClear();

        element.shadowRoot
            .querySelector('lightning-combobox')
            .dispatchEvent(new CustomEvent('change', { detail: { value: 'SMS' } }));
        await settle();

        expect(getConsentSummaries).toHaveBeenCalledWith(
            expect.objectContaining({ channel: 'SMS' })
        );
    });

    it('shows an empty state rather than a blank card when nothing matches', async () => {
        getConsentSummaries.mockResolvedValue([]);
        const element = mount();
        await settle();

        expect(element.shadowRoot.querySelector('lightning-datatable')).toBeNull();
        expect(element.shadowRoot.textContent).toContain('No consent records match this filter');
    });

    it('surfaces an Apex error as readable text, never [object Object]', async () => {
        getConsentSummaries.mockRejectedValue({ body: { message: 'Unable to load consent records.' } });
        const element = mount();
        await settle();

        const alert = element.shadowRoot.querySelector('.slds-alert_error');
        expect(alert).not.toBeNull();
        expect(alert.textContent).toContain('Unable to load consent records.');
        expect(alert.textContent).not.toContain('[object Object]');
    });

    it('sorts nulls last regardless of direction', async () => {
        getConsentSummaries.mockResolvedValue([
            { ...SUMMARY, preferenceId: '1', contactName: 'Zoe' },
            { ...SUMMARY, preferenceId: '2', contactName: null },
            { ...SUMMARY, preferenceId: '3', contactName: 'Alice' }
        ]);
        const element = mount();
        await settle();

        const table = element.shadowRoot.querySelector('lightning-datatable');
        table.dispatchEvent(
            new CustomEvent('sort', { detail: { fieldName: 'contactName', sortDirection: 'asc' } })
        );
        await settle();

        const sorted = element.shadowRoot.querySelector('lightning-datatable').data;
        expect(sorted[0].contactName).toBe('Alice');
        expect(sorted[sorted.length - 1].contactName).toBeNull();
    });

    it('clears its pending debounce on disconnect', async () => {
        jest.useFakeTimers();
        getConsentSummaries.mockResolvedValue([]);
        const element = mount();
        await settle();

        const input = element.shadowRoot.querySelector('lightning-input');
        input.value = 'dana';
        input.dispatchEvent(new CustomEvent('change'));

        document.body.removeChild(element);
        getConsentSummaries.mockClear();
        jest.advanceTimersByTime(1000);

        // A timer left running would call Apex against a destroyed component.
        expect(getConsentSummaries).not.toHaveBeenCalled();
    });
});
