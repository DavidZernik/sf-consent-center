import { LightningElement } from 'lwc';

const STORAGE_KEY = 'consent-center.intro-collapsed';

/**
 * Portfolio introduction.
 *
 * Deliberately styled to sit OUTSIDE the Salesforce chrome rather than inside it. A notice
 * styled to look like part of the app reads as part of the app, and people stop seeing it.
 *
 * Expanded on a first visit because the explanation is the point of the page; collapsible
 * because a returning reader who is here to browse code should not have to scroll past it
 * every time. The choice is remembered for the session only — a link shared with someone
 * new always opens on the introduction.
 */
export default class DemoBanner extends LightningElement {
    expanded = true;

    portfolioUrl = 'https://davidz-losangeles.com/';
    repoUrl = 'https://github.com/DavidZernik/sf-consent-center';

    connectedCallback() {
        // sessionStorage is unavailable in some privacy modes; the default is fine there.
        try {
            this.expanded = sessionStorage.getItem(STORAGE_KEY) !== 'true';
        } catch {
            this.expanded = true;
        }
    }

    handleToggle() {
        this.expanded = !this.expanded;
        try {
            sessionStorage.setItem(STORAGE_KEY, String(!this.expanded));
        } catch {
            // Preference is not persisted. The toggle still works for this view.
        }
    }

    handleViewSource() {
        this.dispatchEvent(
            new CustomEvent('viewsource', { detail: {}, bubbles: true, composed: true })
        );
    }
}
