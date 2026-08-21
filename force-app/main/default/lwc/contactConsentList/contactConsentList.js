import { LightningElement, api, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getConsentSummaries from '@salesforce/apex/ConsentService.getConsentSummaries';

const SEARCH_DEBOUNCE_MS = 300;

const CHANNEL_OPTIONS = [
    { label: 'All channels', value: 'All' },
    { label: 'Email', value: 'Email' },
    { label: 'SMS', value: 'SMS' },
    { label: 'Push', value: 'Push' },
    { label: 'Direct Mail', value: 'Direct Mail' }
];

const COLUMNS = [
    {
        label: 'Contact',
        fieldName: 'contactName',
        type: 'button',
        sortable: true,
        typeAttributes: { label: { fieldName: 'contactName' }, variant: 'base', name: 'view' },
        cellAttributes: { class: 'slds-text-link' }
    },
    { label: 'Email', fieldName: 'email', type: 'email', sortable: true },
    { label: 'Channel', fieldName: 'channel', type: 'text', sortable: true, initialWidth: 130 },
    {
        // Deliberately not type 'boolean'. The datatable's boolean cell renders a tick when true
        // and NOTHING when false, so an opted-out row is visually identical to a row with no
        // consent record at all. On a consent screen that ambiguity is unacceptable. The state
        // has to be stated in words.
        label: 'Consent',
        fieldName: 'consentLabel',
        type: 'text',
        sortable: true,
        initialWidth: 110,
        cellAttributes: { class: { fieldName: 'consentClass' } }
    },
    { label: 'Source', fieldName: 'consentSource', type: 'text' },
    {
        label: 'Last changed',
        fieldName: 'lastChanged',
        type: 'date',
        sortable: true,
        typeAttributes: { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' }
    },
    {
        label: 'Sync',
        fieldName: 'syncStatus',
        type: 'text',
        initialWidth: 110,
        cellAttributes: { class: { fieldName: 'syncStatusClass' } }
    }
];

/**
 * Consent list view.
 *
 * Apex is called imperatively rather than through @wire because the arguments change on every
 * keystroke and every filter change. A cacheable @wire would re-provision on each new config
 * and give no way to debounce; imperative calls let the component own that timing.
 */
export default class ContactConsentList extends NavigationMixin(LightningElement) {
    /** Rows to request. Exposed so the component can be reused on a narrower page. */
    @api maxRows = 200;

    @track rows = [];
    columns = COLUMNS;
    channelOptions = CHANNEL_OPTIONS;

    searchTerm = '';
    selectedChannel = 'All';
    isLoading = false;
    errorMessage;

    sortedBy = 'lastChanged';
    sortDirection = 'desc';

    _debounceHandle;

    connectedCallback() {
        this.loadRows();
    }

    disconnectedCallback() {
        // Without this, a pending debounce fires against a destroyed component.
        clearTimeout(this._debounceHandle);
    }

    /* ------------------------------------------------------------------- Getters */

    get hasRows() {
        return this.rows.length > 0;
    }

    get isEmpty() {
        return !this.isLoading && !this.errorMessage && this.rows.length === 0;
    }

    get resultCountLabel() {
        const count = this.rows.length;
        return `${count} ${count === 1 ? 'record' : 'records'}`;
    }

    /* ------------------------------------------------------------------ Handlers */

    handleSearchChange(event) {
        const value = event.target.value;
        clearTimeout(this._debounceHandle);
        // Handle is retained and cleared in disconnectedCallback, so no timer outlives the
        // component, which is the leak this rule exists to prevent.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._debounceHandle = setTimeout(() => {
            this.searchTerm = value;
            this.loadRows();
        }, SEARCH_DEBOUNCE_MS);
    }

    handleChannelChange(event) {
        this.selectedChannel = event.detail.value;
        this.loadRows();
    }

    handleRefresh() {
        this.loadRows();
    }

    handleRowAction(event) {
        if (event.detail.action.name !== 'view') {
            return;
        }
        const { contactId } = event.detail.row;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: contactId, objectApiName: 'Contact', actionName: 'view' }
        });
    }

    handleSort(event) {
        const { fieldName, sortDirection } = event.detail;
        const multiplier = sortDirection === 'asc' ? 1 : -1;
        // Sorting a copy keeps the tracked array reference change explicit for the renderer.
        const sorted = [...this.rows].sort((a, b) => {
            const left = a[fieldName];
            const right = b[fieldName];
            if (left === right) return 0;
            if (left === null || left === undefined) return 1;
            if (right === null || right === undefined) return -1;
            return left > right ? multiplier : -multiplier;
        });
        this.rows = sorted;
        this.sortedBy = fieldName;
        this.sortDirection = sortDirection;
    }

    /* ------------------------------------------------------------------- Loading */

    async loadRows() {
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            const data = await getConsentSummaries({
                searchTerm: this.searchTerm,
                channel: this.selectedChannel
            });
            this.rows = data.map((row) => ({
                ...row,
                consentLabel: row.optIn ? 'Opted in' : 'Opted out',
                consentClass: row.optIn
                    ? 'slds-text-color_success slds-text-title_bold'
                    : 'slds-text-color_error',
                syncStatusClass: this.syncStatusClass(row.syncStatus)
            }));
        } catch (error) {
            this.rows = [];
            this.errorMessage = this.readableError(error);
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Could not load consent records',
                    message: this.errorMessage,
                    variant: 'error'
                })
            );
        } finally {
            this.isLoading = false;
        }
    }

    syncStatusClass(status) {
        if (status === 'Failed') return 'slds-text-color_error';
        if (status === 'Pending') return 'slds-text-color_weak';
        return 'slds-text-color_success';
    }

    /**
     * Apex errors arrive in several shapes depending on how they were raised, so every one is
     * handled rather than letting "[object Object]" reach the user.
     */
    readableError(error) {
        if (!error) return 'Unknown error.';
        if (Array.isArray(error.body)) return error.body.map((e) => e.message).join(', ');
        if (error.body?.message) return error.body.message;
        if (typeof error.message === 'string') return error.message;
        return 'Unknown error.';
    }
}
