import { LightningElement } from 'lwc';

/**
 * Portfolio banner.
 *
 * Deliberately styled to sit OUTSIDE the Salesforce chrome rather than inside it. A notice
 * styled to look like part of the app reads as part of the app, and people stop seeing it.
 */
export default class DemoBanner extends LightningElement {
    portfolioUrl = 'https://davidz-losangeles.com/';
    repoUrl = 'https://github.com/DavidZernik/sf-consent-center';

    handleViewSource() {
        this.dispatchEvent(
            new CustomEvent('viewsource', { detail: {}, bubbles: true, composed: true })
        );
    }
}
