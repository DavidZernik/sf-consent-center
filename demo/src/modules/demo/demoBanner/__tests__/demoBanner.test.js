import { createElement } from 'lwc';
import DemoBanner from 'demo/demoBanner';

const SESSION_KEY = 'consent-center.intro-collapsed';

function render() {
    const el = createElement('demo-demo-banner', { is: DemoBanner });
    document.body.appendChild(el);
    return el;
}

function text(el) {
    return el.shadowRoot.textContent.replace(/\s+/g, ' ');
}

describe('demoBanner', () => {
    afterEach(() => {
        sessionStorage.clear();
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('opens on the introduction for a first-time visitor', () => {
        // The explanation is the point of the page; a visitor arriving from a resume link
        // should not have to find it.
        const el = render();
        expect(el.shadowRoot.querySelector('.intro')).not.toBeNull();
        expect(el.shadowRoot.querySelector('.banner-inner')).toBeNull();
    });

    it('answers the questions a reader arrives with', () => {
        const body = text(render());
        expect(body).toContain('Who I am');
        expect(body).toContain('How it works');
        expect(body).toContain('What it demonstrates');
        expect(body).toContain('David Zernik');
    });

    it('names the actual Salesforce languages rather than gesturing at them', () => {
        // "Real Salesforce code" is a claim anyone can type. Naming Apex, SOQL, SOSL,
        // Visualforce and Flow is what makes it checkable against the source viewer.
        const body = text(render());
        for (const term of ['Apex', 'LWC', 'SOQL', 'SOSL', 'Visualforce', 'Flow', 'Lightning Web Components']) {
            expect(body).toContain(term);
        }
    });

    it('collapses to a one-line strip and remembers that for the session', () => {
        const el = render();
        el.shadowRoot.querySelector('.toggle').click();
        return Promise.resolve().then(() => {
            expect(el.shadowRoot.querySelector('.intro')).toBeNull();
            expect(el.shadowRoot.querySelector('.banner-inner')).not.toBeNull();
            expect(sessionStorage.getItem(SESSION_KEY)).toBe('true');

            // A second visit within the session honours the choice.
            const again = render();
            expect(again.shadowRoot.querySelector('.intro')).toBeNull();
        });
    });

    it('reopens from the collapsed strip', () => {
        sessionStorage.setItem(SESSION_KEY, 'true');
        const el = render();
        el.shadowRoot.querySelector('.toggle').click();
        return Promise.resolve().then(() => {
            expect(el.shadowRoot.querySelector('.intro')).not.toBeNull();
            expect(sessionStorage.getItem(SESSION_KEY)).toBe('false');
        });
    });

    it('raises viewsource from both states so the source panel is always one click away', () => {
        const el = render();
        const handler = jest.fn();
        el.addEventListener('viewsource', handler);

        el.shadowRoot.querySelector('.link-button').click();
        expect(handler).toHaveBeenCalledTimes(1);

        el.shadowRoot.querySelector('.toggle').click();
        return Promise.resolve().then(() => {
            el.shadowRoot.querySelector('.link-button').click();
            expect(handler).toHaveBeenCalledTimes(2);
        });
    });

    it('still renders when sessionStorage throws', () => {
        // Safari private browsing throws on access rather than returning null.
        const spy = jest.spyOn(Storage.prototype, 'getItem').mockImplementation(() => {
            throw new Error('denied');
        });
        try {
            expect(render().shadowRoot.querySelector('.intro')).not.toBeNull();
        } finally {
            spy.mockRestore();
        }
    });
});
