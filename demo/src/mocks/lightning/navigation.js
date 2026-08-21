/**
 * Stand-in for lightning/navigation.
 *
 * NavigationMixin is a real mixin on the platform, so this is one too. Components call
 * this[NavigationMixin.Navigate](pageReference) exactly as they would in an org. Instead of a
 * page transition, the mock dispatches a window event that the demo's router listens for, which
 * is how a standard__recordPage reference becomes a route change in the browser.
 */

const Navigate = Symbol('Navigate');
const GenerateUrl = Symbol('GenerateUrl');

export function NavigationMixin(Base) {
    return class extends Base {
        [Navigate](pageReference, replace = false) {
            window.dispatchEvent(
                new CustomEvent('demo__navigate', { detail: { pageReference, replace } })
            );
        }

        [GenerateUrl](pageReference) {
            return Promise.resolve(toHash(pageReference));
        }
    };
}

NavigationMixin.Navigate = Navigate;
NavigationMixin.GenerateUrl = GenerateUrl;

/** Translates a Lightning page reference into this demo's hash route. */
export function toHash(pageReference) {
    if (pageReference?.type === 'standard__recordPage') {
        return `#/contact/${pageReference.attributes.recordId}`;
    }
    if (pageReference?.type === 'standard__navItemPage') {
        return `#/${pageReference.attributes.apiName}`;
    }
    return '#/';
}

export const CurrentPageReference = Symbol('CurrentPageReference');
