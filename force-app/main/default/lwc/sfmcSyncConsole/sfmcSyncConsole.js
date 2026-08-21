import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getSyncLogs from '@salesforce/apex/ConsentService.getSyncLogs';
import retrySync from '@salesforce/apex/ConsentService.retrySync';

const STATUS_OPTIONS = [
    { label: 'All activity', value: 'All' },
    { label: 'Failed', value: 'Failed' },
    { label: 'Retrying', value: 'Retrying' },
    { label: 'Success', value: 'Success' }
];

const COLUMNS = [
    { label: 'Contact', fieldName: 'contactName', type: 'text' },
    { label: 'Channel', fieldName: 'channel', type: 'text', initialWidth: 110 },
    { label: 'Status', fieldName: 'status', type: 'text', initialWidth: 100, cellAttributes: { class: { fieldName: 'statusClass' } } },
    { label: 'Attempt', fieldName: 'attempt', type: 'number', initialWidth: 115, cellAttributes: { alignment: 'center' } },
    { label: 'HTTP', fieldName: 'statusCode', type: 'number', initialWidth: 80, cellAttributes: { alignment: 'center' } },
    { label: 'Data Extension', fieldName: 'dataExtensionKey', type: 'text' },
    { label: 'Duration', fieldName: 'durationLabel', type: 'text', initialWidth: 100, cellAttributes: { alignment: 'right' } },
    { label: 'Error', fieldName: 'errorMessage', type: 'text', wrapText: true },
    {
        label: 'Processed',
        fieldName: 'processedAt',
        type: 'date',
        initialWidth: 160,
        typeAttributes: { month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' }
    }
];

/**
 * Operations console for the Marketing Cloud sync.
 *
 * The retry action is intentionally the only mutation here: everything else about the sync is
 * driven by the async jobs, and giving an operator a manual edit path would let the console
 * disagree with what was actually delivered.
 */
export default class SfmcSyncConsole extends LightningElement {
    @track rows = [];
    columns = COLUMNS;
    statusOptions = STATUS_OPTIONS;

    selectedStatus = 'All';
    selectedIds = [];
    isLoading = false;
    isRetrying = false;
    errorMessage;

    connectedCallback() {
        this.loadLogs();
    }

    /* ------------------------------------------------------------------- Getters */

    get hasRows() {
        return this.rows.length > 0;
    }

    get isEmpty() {
        return !this.isLoading && !this.errorMessage && this.rows.length === 0;
    }

    get isRetryDisabled() {
        return this.selectedIds.length === 0 || this.isRetrying;
    }

    get retryLabel() {
        return this.selectedIds.length > 0 ? `Retry ${this.selectedIds.length} selected` : 'Retry selected';
    }

    /** Headline counts, computed client side because the rows are already here. */
    get stats() {
        const tally = { Success: 0, Retrying: 0, Failed: 0 };
        for (const row of this.rows) {
            if (tally[row.status] !== undefined) {
                tally[row.status]++;
            }
        }
        return [
            { key: 'Success', label: 'Delivered', value: tally.Success, className: 'stat-value slds-text-color_success' },
            { key: 'Retrying', label: 'Retrying', value: tally.Retrying, className: 'stat-value slds-text-color_weak' },
            { key: 'Failed', label: 'Failed', value: tally.Failed, className: 'stat-value slds-text-color_error' }
        ];
    }

    /* ------------------------------------------------------------------ Handlers */

    handleStatusChange(event) {
        this.selectedStatus = event.detail.value;
        this.selectedIds = [];
        this.loadLogs();
    }

    handleRowSelection(event) {
        this.selectedIds = event.detail.selectedRows.map((row) => row.logId);
    }

    handleRefresh() {
        this.loadLogs();
    }

    async handleRetry() {
        if (this.selectedIds.length === 0) {
            return;
        }
        this.isRetrying = true;
        try {
            const result = await retrySync({ logIds: this.selectedIds });
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Retry queued',
                    message: result.message,
                    variant: result.queued > 0 ? 'success' : 'warning'
                })
            );
            this.selectedIds = [];
            await this.loadLogs();
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Could not queue the retry',
                    message: this.readableError(error),
                    variant: 'error',
                    mode: 'sticky'
                })
            );
        } finally {
            this.isRetrying = false;
        }
    }

    /* ------------------------------------------------------------------- Loading */

    async loadLogs() {
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            const data = await getSyncLogs({ status: this.selectedStatus });
            this.rows = data.map((row) => ({
                ...row,
                statusClass: this.statusClass(row.status),
                durationLabel: row.durationMs === null || row.durationMs === undefined ? '-' : `${row.durationMs} ms`
            }));
        } catch (error) {
            this.rows = [];
            this.errorMessage = this.readableError(error);
        } finally {
            this.isLoading = false;
        }
    }

    statusClass(status) {
        if (status === 'Failed') return 'slds-text-color_error';
        if (status === 'Retrying') return 'slds-text-color_weak';
        return 'slds-text-color_success';
    }

    readableError(error) {
        if (!error) return 'Unknown error.';
        if (Array.isArray(error.body)) return error.body.map((e) => e.message).join(', ');
        if (error.body?.message) return error.body.message;
        if (typeof error.message === 'string') return error.message;
        return 'Unknown error.';
    }
}
