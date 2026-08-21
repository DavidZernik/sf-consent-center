import { createElement } from 'lwc';
import ViewSourcePanel from 'demo/viewSourcePanel';

/**
 * Tests for the source panel.
 *
 * This component is the one part of the demo with no platform equivalent and the part a reviewer
 * is most likely to click first, so it is covered end to end: lazy manifest fetch, grouping,
 * filtering, the manual code render, and the failure path when the manifest cannot be loaded.
 */

const MANIFEST = {
    files: {
        'force-app/main/default/classes/ConsentService.cls': {
            group: 'Apex classes',
            content: 'public with sharing class ConsentService {\n    // boundary\n}'
        },
        'force-app/main/default/classes/SfmcClient.cls': {
            group: 'Apex classes',
            content: 'public with sharing class SfmcClient {\n}'
        },
        'force-app/main/default/lwc/contactConsentList/contactConsentList.js': {
            group: 'Lightning Web Components',
            content: "import { LightningElement } from 'lwc';\nexport default class A extends LightningElement {}"
        }
    }
};

function mount() {
    const element = createElement('demo-view-source-panel', { is: ViewSourcePanel });
    document.body.appendChild(element);
    return element;
}

async function settle(times = 4) {
    for (let i = 0; i < times; i++) {
        await Promise.resolve();
    }
}

describe('demo-view-source-panel', () => {
    beforeEach(() => {
        global.fetch = jest.fn().mockResolvedValue({
            ok: true,
            status: 200,
            json: () => Promise.resolve(MANIFEST)
        });
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
        delete global.fetch;
    });

    it('starts closed and fetches nothing until it is opened', () => {
        const element = mount();
        expect(element.shadowRoot.querySelector('.source-panel').className).not.toContain('is-open');
        // The manifest is a few hundred KB; a viewer who never opens the panel should not pay for it.
        expect(global.fetch).not.toHaveBeenCalled();
    });

    it('fetches the manifest with a relative URL so a Pages subpath resolves', async () => {
        const element = mount();
        await element.open();
        await settle();

        expect(global.fetch).toHaveBeenCalledWith('./sources.json');
        // An absolute /sources.json would 404 under username.github.io/repo-name/.
        expect(global.fetch.mock.calls[0][0].startsWith('./')).toBe(true);
    });

    it('opens at the requested file', async () => {
        const element = mount();
        await element.open('force-app/main/default/classes/SfmcClient.cls');
        await settle();

        expect(element.shadowRoot.querySelector('.source-panel').className).toContain('is-open');
        expect(element.shadowRoot.querySelector('.code-path').textContent).toBe(
            'force-app/main/default/classes/SfmcClient.cls'
        );
    });

    it('falls back to the first file when the requested path is unknown', async () => {
        const element = mount();
        await element.open('force-app/main/default/classes/DoesNotExist.cls');
        await settle();

        const path = element.shadowRoot.querySelector('.code-path').textContent;
        expect(Object.keys(MANIFEST.files)).toContain(path);
    });

    it('groups files by their manifest group', async () => {
        const element = mount();
        await element.open();
        await settle();

        const labels = [...element.shadowRoot.querySelectorAll('.tree-group-label')].map(
            (node) => node.textContent
        );
        expect(labels).toEqual(['Apex classes', 'Lightning Web Components']);
        expect(element.shadowRoot.querySelectorAll('.file-item')).toHaveLength(3);
    });

    it('filters the file list on the path, not just the file name', async () => {
        const element = mount();
        await element.open();
        await settle();

        const input = element.shadowRoot.querySelector('.filter-input');
        input.value = 'lwc/';
        input.dispatchEvent(new CustomEvent('input'));
        await settle();

        const items = element.shadowRoot.querySelectorAll('.file-item');
        expect(items).toHaveLength(1);
        expect(items[0].textContent).toBe('contactConsentList.js');
    });

    it('shows an empty state when the filter matches nothing', async () => {
        const element = mount();
        await element.open();
        await settle();

        const input = element.shadowRoot.querySelector('.filter-input');
        input.value = 'zzzz-no-such-file';
        input.dispatchEvent(new CustomEvent('input'));
        await settle();

        expect(element.shadowRoot.textContent).toContain('No files match that filter');
    });

    it('renders gutter line numbers matching the file length', async () => {
        const element = mount();
        await element.open('force-app/main/default/classes/ConsentService.cls');
        await settle();

        const container = element.shadowRoot.querySelector('[data-code-container]');
        const gutter = container.querySelector('.gutter');
        expect(gutter).not.toBeNull();
        // The fixture is three lines long.
        expect(gutter.textContent.trim().split('\n')).toEqual(['1', '2', '3']);
    });

    it('renders highlighted code rather than raw text', async () => {
        const element = mount();
        await element.open('force-app/main/default/classes/ConsentService.cls');
        await settle();

        const code = element.shadowRoot.querySelector('[data-code-container] .code');
        expect(code.innerHTML).toContain('tok-keyword');
        expect(code.textContent).toContain('class ConsentService');
    });

    it('switches files when a different one is selected', async () => {
        const element = mount();
        await element.open('force-app/main/default/classes/ConsentService.cls');
        await settle();

        const target = [...element.shadowRoot.querySelectorAll('.file-item')].find(
            (item) => item.textContent === 'contactConsentList.js'
        );
        target.click();
        await settle();

        expect(element.shadowRoot.querySelector('.code-path').textContent).toContain(
            'contactConsentList.js'
        );
    });

    it('fetches the manifest once across repeated opens', async () => {
        const element = mount();
        await element.open();
        await settle();
        element.close();
        await element.open('force-app/main/default/classes/SfmcClient.cls');
        await settle();

        expect(global.fetch).toHaveBeenCalledTimes(1);
    });

    it('closes on the backdrop and on Escape', async () => {
        const element = mount();
        await element.open();
        await settle();

        element.shadowRoot.querySelector('.backdrop').click();
        await settle();
        expect(element.shadowRoot.querySelector('.source-panel').className).not.toContain('is-open');

        await element.open();
        await settle();
        element.shadowRoot
            .querySelector('.source-panel')
            .dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
        await settle();
        expect(element.shadowRoot.querySelector('.source-panel').className).not.toContain('is-open');
    });

    it('reports a failed manifest fetch instead of rendering an empty panel', async () => {
        global.fetch = jest.fn().mockResolvedValue({ ok: false, status: 404 });
        const element = mount();
        await element.open();
        await settle();

        expect(element.shadowRoot.querySelector('.error-text').textContent).toContain('HTTP 404');
    });

    it('reports a network failure', async () => {
        global.fetch = jest.fn().mockRejectedValue(new Error('offline'));
        const element = mount();
        await element.open();
        await settle();

        expect(element.shadowRoot.querySelector('.error-text').textContent).toContain('offline');
    });
});
