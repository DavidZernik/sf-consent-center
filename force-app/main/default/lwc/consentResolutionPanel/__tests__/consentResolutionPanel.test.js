import { createElement } from 'lwc';
import ConsentResolutionPanel from 'c/consentResolutionPanel';

const RESOLVED = [
    {
        channel: 'Email',
        optIn: false,
        isConflicted: true,
        sourcesTotal: 3,
        sourcesAgreeing: 1,
        reason: '1 of 3 sources recorded an opt-out. Most restrictive wins, so the unified profile is opted out.'
    },
    {
        channel: 'SMS',
        optIn: true,
        isConflicted: false,
        sourcesTotal: 2,
        sourcesAgreeing: 2,
        reason: 'All 2 sources agree on opt-in.'
    }
];

const SOURCES = [
    { sourceRecordId: 'a', sourceSystem: 'CRM', channel: 'Email', optIn: true },
    { sourceRecordId: 'b', sourceSystem: 'POS', channel: 'Email', optIn: false },
    { sourceRecordId: 'c', sourceSystem: 'Loyalty', channel: 'Email', optIn: true },
    { sourceRecordId: 'a', sourceSystem: 'CRM', channel: 'SMS', optIn: true },
    { sourceRecordId: 'c', sourceSystem: 'Loyalty', channel: 'SMS', optIn: true }
];

function mount(resolved = RESOLVED, sources = SOURCES) {
    const element = createElement('c-consent-resolution-panel', { is: ConsentResolutionPanel });
    element.resolved = resolved;
    element.sources = sources;
    document.body.appendChild(element);
    return element;
}

describe('c-consent-resolution-panel', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('flags the conflicted channel and counts it', () => {
        const element = mount();
        expect(element.shadowRoot.textContent).toContain('1 channel has conflicting source records');
        expect(element.shadowRoot.querySelectorAll('.channel-block.conflicted')).toHaveLength(1);
    });

    it('marks the source that decided an opt-out outcome', () => {
        const element = mount();
        const emailBlock = element.shadowRoot.querySelector('.channel-block.conflicted');
        // The POS opt-out is what forced the answer, so it must be visibly attributed.
        expect(emailBlock.textContent).toContain('decided the outcome');
        expect(emailBlock.textContent).toContain('POS');
    });

    it('does not mark any source as decisive when the answer is opt-in', () => {
        const element = mount();
        const blocks = [...element.shadowRoot.querySelectorAll('.channel-block')];
        const smsBlock = blocks.find((block) => block.textContent.includes('SMS'));
        expect(smsBlock.textContent).not.toContain('decided the outcome');
    });

    it('shows the reasoning, not just the answer', () => {
        const element = mount();
        expect(element.shadowRoot.textContent).toContain('Most restrictive wins');
    });

    it('renders an empty state when Data Cloud returned nothing', () => {
        const element = mount([], []);
        expect(element.shadowRoot.textContent).toContain('No consent records found in Data Cloud');
    });

    it('tolerates non-array input without throwing', () => {
        const element = createElement('c-consent-resolution-panel', { is: ConsentResolutionPanel });
        element.resolved = null;
        element.sources = undefined;
        document.body.appendChild(element);
        expect(element.shadowRoot.textContent).toContain('No consent records found');
    });
});
