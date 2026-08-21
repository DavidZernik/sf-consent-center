import { LightningElement, api } from 'lwc';

const VARIANT_BY_STATUS = {
    Synced: 'slds-theme_success',
    Success: 'slds-theme_success',
    Pending: 'slds-badge_lightest',
    Retrying: 'slds-theme_warning',
    Failed: 'slds-theme_error'
};

/**
 * Presentational status pill. Deliberately stateless and free of Apex so it can be dropped
 * anywhere and unit tested without mocking a wire.
 */
export default class ConsentStatusBadge extends LightningElement {
    @api status;

    get label() {
        return this.status || 'Unknown';
    }

    get badgeClass() {
        const theme = VARIANT_BY_STATUS[this.status] ?? 'slds-badge_lightest';
        return `slds-badge ${theme}`;
    }
}
