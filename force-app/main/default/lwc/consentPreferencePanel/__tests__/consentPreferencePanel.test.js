import { createElement } from 'lwc';
import ConsentPreferencePanel from 'c/consentPreferencePanel';
import getConsentDetail from '@salesforce/apex/ConsentService.getConsentDetail';
import savePreferences from '@salesforce/apex/ConsentService.savePreferences';

jest.mock('@salesforce/apex/ConsentService.getConsentDetail', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ConsentService.savePreferences', () => ({ default: jest.fn() }), { virtual: true });

const DETAIL = {
    contactId: '0031',
    contactName: 'Dana Reyes',
    email: 'dana@example.invalid',
    lifecycleStage: 'Engaged',
    preferences: [
        { preferenceId: 'a1', channel: 'Email', optIn: true, syncStatus: 'Synced', lastChanged: '2026-08-01T00:00:00.000Z' },
        { preferenceId: 'a2', channel: 'SMS', optIn: false, syncStatus: 'Synced', lastChanged: '2026-08-01T00:00:00.000Z' }
    ],
    history: []
};

async function settle() {
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
}

function mount() {
    const element = createElement('c-consent-preference-panel', { is: ConsentPreferencePanel });
    element.recordId = '0031';
    document.body.appendChild(element);
    return element;
}

function toggleFor(element, channel) {
    return [...element.shadowRoot.querySelectorAll('lightning-input')].find(
        (input) => input.dataset.channel === channel
    );
}

describe('c-consent-preference-panel', () => {
    beforeEach(() => {
        getConsentDetail.mockResolvedValue(JSON.parse(JSON.stringify(DETAIL)));
        savePreferences.mockResolvedValue(JSON.parse(JSON.stringify(DETAIL)));
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('renders every known channel, including ones with no record', async () => {
        const element = mount();
        await settle();

        // Query by data-channel, not [type="toggle"]: base components receive `type` as a
        // property, so an attribute selector never matches under the stubs.
        const toggles = [...element.shadowRoot.querySelectorAll('lightning-input')].filter(
            (input) => input.dataset.channel
        );
        // Apex returned two channels; the component must still offer all four.
        expect(toggles).toHaveLength(4);
        expect(toggleFor(element, 'Push')).toBeDefined();
        expect(toggleFor(element, 'Direct Mail')).toBeDefined();
    });

    it('disables save until something actually changes', async () => {
        const element = mount();
        await settle();

        const saveButton = [...element.shadowRoot.querySelectorAll('lightning-button')].find(
            (button) => button.label === 'Save'
        );
        expect(saveButton.disabled).toBe(true);

        const toggle = toggleFor(element, 'Email');
        toggle.checked = false;
        toggle.dispatchEvent(new CustomEvent('change'));
        await settle();

        const enabled = [...element.shadowRoot.querySelectorAll('lightning-button')].find(
            (button) => button.label === 'Save'
        );
        expect(enabled.disabled).toBe(false);
    });

    it('submits only the channels that changed', async () => {
        const element = mount();
        await settle();

        const toggle = toggleFor(element, 'SMS');
        toggle.checked = true;
        toggle.dispatchEvent(new CustomEvent('change'));
        await settle();

        [...element.shadowRoot.querySelectorAll('lightning-button')]
            .find((button) => button.label === 'Save')
            .dispatchEvent(new CustomEvent('click'));
        await settle();

        expect(savePreferences).toHaveBeenCalledTimes(1);
        const payload = JSON.parse(savePreferences.mock.calls[0][0].changesJson);
        // Only SMS moved. Sending Email as well would write a meaningless audit row.
        expect(payload).toEqual([{ channel: 'SMS', optIn: true }]);
    });

    it('reverts to the loaded state on reset', async () => {
        const element = mount();
        await settle();

        const toggle = toggleFor(element, 'Email');
        toggle.checked = false;
        toggle.dispatchEvent(new CustomEvent('change'));
        await settle();

        [...element.shadowRoot.querySelectorAll('lightning-button')]
            .find((button) => button.label === 'Reset')
            .dispatchEvent(new CustomEvent('click'));
        await settle();

        const saveButton = [...element.shadowRoot.querySelectorAll('lightning-button')].find(
            (button) => button.label === 'Save'
        );
        expect(saveButton.disabled).toBe(true);
    });

    it('dispatches a composed consentchange event so the shell can refresh', async () => {
        const element = mount();
        await settle();
        const listener = jest.fn();
        element.addEventListener('consentchange', listener);

        const toggle = toggleFor(element, 'SMS');
        toggle.checked = true;
        toggle.dispatchEvent(new CustomEvent('change'));
        await settle();

        [...element.shadowRoot.querySelectorAll('lightning-button')]
            .find((button) => button.label === 'Save')
            .dispatchEvent(new CustomEvent('click'));
        await settle();

        expect(listener).toHaveBeenCalled();
        expect(listener.mock.calls[0][0].detail.contactId).toBe('0031');
    });

    it('fires a toast when the save fails and does not silently swallow the error', async () => {
        savePreferences.mockRejectedValue({ body: { message: 'Unsupported channel: Carrier Pigeon' } });
        const element = mount();
        await settle();

        const toastListener = jest.fn();
        element.addEventListener('lightning__showtoast', toastListener);

        const toggle = toggleFor(element, 'SMS');
        toggle.checked = true;
        toggle.dispatchEvent(new CustomEvent('change'));
        await settle();

        [...element.shadowRoot.querySelectorAll('lightning-button')]
            .find((button) => button.label === 'Save')
            .dispatchEvent(new CustomEvent('click'));
        await settle();

        expect(toastListener).toHaveBeenCalled();
        const detail = toastListener.mock.calls[0][0].detail;
        expect(detail.variant).toBe('error');
        expect(detail.message).toContain('Carrier Pigeon');
    });

    it('reloads when the record id changes', async () => {
        const element = mount();
        await settle();
        expect(getConsentDetail).toHaveBeenCalledTimes(1);

        element.recordId = '0032';
        await settle();

        expect(getConsentDetail).toHaveBeenCalledTimes(2);
        expect(getConsentDetail).toHaveBeenLastCalledWith({ contactId: '0032' });
    });
});
