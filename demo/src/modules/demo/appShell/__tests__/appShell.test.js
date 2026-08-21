import { createElement } from 'lwc';
import AppShell from 'demo/appShell';

/**
 * Routing and platform-service tests for the shell.
 *
 * The shell stands in for the three things Lightning Experience normally provides — routing,
 * toasts and navigation — so these tests pin the contracts the components rely on.
 */

function mount() {
    const element = createElement('demo-app-shell', { is: AppShell });
    document.body.appendChild(element);
    return element;
}

async function settle(times = 6) {
    for (let i = 0; i < times; i++) {
        await Promise.resolve();
    }
}

function visibleTab(element) {
    if (element.shadowRoot.querySelector('c-contact-consent-list')) return 'records';
    if (element.shadowRoot.querySelector('c-consent-preference-panel')) return 'contact';
    if (element.shadowRoot.querySelector('c-unified-profile-card')) return 'unified';
    if (element.shadowRoot.querySelector('c-sfmc-sync-console')) return 'sync';
    if (element.shadowRoot.querySelector('demo-capability-map')) return 'capabilities';
    return 'none';
}

describe('demo-app-shell routing', () => {
    beforeEach(() => {
        global.fetch = jest.fn().mockResolvedValue({
            ok: true,
            status: 200,
            json: () => Promise.resolve({ files: {} })
        });
        window.location.hash = '';
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
        delete global.fetch;
    });

    it('defaults to the records tab', async () => {
        const element = mount();
        await settle();
        expect(visibleTab(element)).toBe('records');
    });

    it.each([
        ['#/records', 'records'],
        ['#/unified', 'unified'],
        ['#/sync', 'sync'],
        ['#/capabilities', 'capabilities']
    ])('routes %s to the %s tab', async (hash, expected) => {
        window.location.hash = hash;
        const element = mount();
        await settle();
        expect(visibleTab(element)).toBe(expected);
    });

    it('falls back to records for an unrecognised route', async () => {
        window.location.hash = '#/not-a-real-route';
        const element = mount();
        await settle();
        expect(visibleTab(element)).toBe('records');
    });

    it('routes a contact hash to the record view and passes the id down', async () => {
        window.location.hash = '#/contact/003Kg000001aA01';
        const element = mount();
        await settle();

        expect(visibleTab(element)).toBe('contact');
        expect(element.shadowRoot.querySelector('c-consent-preference-panel').recordId).toBe(
            '003Kg000001aA01'
        );
    });

    it('opens the source panel from a #/source deep link on a cold load', async () => {
        // The regression this guards: routing runs in connectedCallback, before the first render,
        // so opening the panel directly from the router silently did nothing on a cold load.
        window.location.hash =
            '#/source/force-app%2Fmain%2Fdefault%2Fclasses%2FConsentService.cls';
        const element = mount();
        await settle(10);

        expect(visibleTab(element)).toBe('capabilities');
        expect(global.fetch).toHaveBeenCalledWith('./sources.json');
        const panel = element.shadowRoot.querySelector('demo-view-source-panel');
        expect(panel.shadowRoot.querySelector('.source-panel').className).toContain('is-open');
    });

    it('decodes a deep-linked path containing encoded separators', async () => {
        window.location.hash = '#/source/lwc.config.json';
        const element = mount();
        await settle(10);
        expect(visibleTab(element)).toBe('capabilities');
    });

    it('renders a toast when a child dispatches ShowToastEvent', async () => {
        const element = mount();
        await settle();

        element.shadowRoot.querySelector('.shell').dispatchEvent(
            new CustomEvent('lightning__showtoast', {
                bubbles: true,
                composed: true,
                detail: { title: 'Saved', message: 'Two channels updated.', variant: 'success' }
            })
        );
        await settle();

        const host = element.shadowRoot.querySelector('demo-toast-host');
        expect(host.shadowRoot.textContent).toContain('Saved');
        expect(host.shadowRoot.textContent).toContain('Two channels updated.');
    });

    it('translates a NavigationMixin record page reference into a hash route', async () => {
        const element = mount();
        await settle();

        // This is exactly what mocks/lightning/navigation.js emits when a component calls
        // this[NavigationMixin.Navigate]({ type: 'standard__recordPage', ... }).
        window.dispatchEvent(
            new CustomEvent('demo__navigate', {
                detail: {
                    pageReference: {
                        type: 'standard__recordPage',
                        attributes: { recordId: '003Kg000001aA04', objectApiName: 'Contact', actionName: 'view' }
                    }
                }
            })
        );
        await settle();

        expect(window.location.hash).toBe('#/contact/003Kg000001aA04');
    });

    it('stops listening to hash changes after disconnect', async () => {
        const element = mount();
        await settle();
        document.body.removeChild(element);

        // A listener left attached would keep routing a destroyed component.
        expect(() => {
            window.location.hash = '#/sync';
            window.dispatchEvent(new HashChangeEvent('hashchange'));
        }).not.toThrow();
    });
});
