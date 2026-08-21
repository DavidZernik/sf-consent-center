import { createElement } from 'lwc';
import ConsentStatusBadge from 'c/consentStatusBadge';

function mount(status) {
    const element = createElement('c-consent-status-badge', { is: ConsentStatusBadge });
    element.status = status;
    document.body.appendChild(element);
    return element;
}

describe('c-consent-status-badge', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it.each([
        ['Synced', 'slds-theme_success'],
        ['Success', 'slds-theme_success'],
        ['Retrying', 'slds-theme_warning'],
        ['Failed', 'slds-theme_error'],
        ['Pending', 'slds-badge_lightest']
    ])('maps %s to the %s theme', (status, expectedClass) => {
        const element = mount(status);
        const badge = element.shadowRoot.querySelector('span');
        expect(badge.className).toContain(expectedClass);
        expect(badge.textContent).toBe(status);
    });

    it('falls back to a neutral badge for an unrecognised status', () => {
        const element = mount('Something New');
        expect(element.shadowRoot.querySelector('span').className).toContain('slds-badge_lightest');
    });

    it('renders Unknown rather than an empty pill when status is absent', () => {
        const element = mount(undefined);
        expect(element.shadowRoot.querySelector('span').textContent).toBe('Unknown');
    });
});
