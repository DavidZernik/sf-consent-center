import { LightningElement, api } from 'lwc';

const STAGES = ['Prospect', 'Subscriber', 'Engaged', 'Lapsed', 'Unsubscribed'];

/**
 * Marketing lifecycle path.
 *
 * lightning-progress-indicator in path mode is the same component Sales Path uses, so this
 * reads as native rather than as a hand-drawn approximation of it.
 */
export default class ConsentLifecyclePath extends LightningElement {
    @api stage;

    get steps() {
        return STAGES.map((label) => ({ label, value: label }));
    }

    get currentStep() {
        return STAGES.includes(this.stage) ? this.stage : STAGES[0];
    }

    /** Unsubscribed is a terminal, undesirable state — path renders it as an error. */
    get hasError() {
        return this.stage === 'Unsubscribed';
    }
}
