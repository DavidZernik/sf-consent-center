/**
 * Stand-in for lightning/platformShowToastEvent.
 *
 * Identical to the platform implementation: a CustomEvent named lightning__showtoast that
 * bubbles and crosses shadow boundaries. Because the contract is the same, component code that
 * dispatches a toast is byte-identical to what would deploy to an org — the demo's app shell
 * simply listens for the event and renders the toast itself, which is what Lightning
 * Experience does natively.
 */
export class ShowToastEvent extends CustomEvent {
    constructor(config) {
        super('lightning__showtoast', {
            bubbles: true,
            cancelable: true,
            composed: true,
            detail: config
        });
    }
}
