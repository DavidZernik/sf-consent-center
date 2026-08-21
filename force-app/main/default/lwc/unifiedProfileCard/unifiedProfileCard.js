import { LightningElement, api, track } from 'lwc';
import getUnifiedProfile from '@salesforce/apex/DataCloudService.getUnifiedProfile';

/**
 * Data Cloud unified profile for one CRM contact.
 *
 * Shows the identity graph (every source record that resolved into this person) alongside the
 * resolved consent position and the engagement Calculated Insight. The point of the component is
 * to make visible something that is otherwise invisible in the CRM UI: that the record you are
 * looking at is one of several, and that consent is answered across all of them.
 */
export default class UnifiedProfileCard extends LightningElement {
    _recordId;

    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
        if (value) {
            this.loadProfile();
        }
    }

    @track profile;
    isLoading = false;
    errorMessage;

    get hasProfile() {
        return Boolean(this.profile);
    }

    get sourceCount() {
        return this.profile?.sources?.length ?? 0;
    }

    get sourceCountLabel() {
        const count = this.sourceCount;
        return `${count} source ${count === 1 ? 'record' : 'records'} resolved`;
    }

    get decoratedSources() {
        return (this.profile?.sources ?? []).map((source) => ({
            ...source,
            key: source.sourceRecordId,
            confidenceLabel:
                source.matchConfidence === null || source.matchConfidence === undefined
                    ? '-'
                    : `${Math.round(source.matchConfidence * 100)}%`,
            // An exact match and a probabilistic one are very different things to an auditor.
            isExactMatch: source.matchConfidence >= 1,
            confidenceClass:
                source.matchConfidence >= 1
                    ? 'slds-badge slds-theme_success'
                    : 'slds-badge slds-badge_lightest'
        }));
    }

    get queryTimingLabel() {
        return this.profile?.queryDurationMs === undefined
            ? ''
            : `3 Data Cloud queries · ${this.profile.queryDurationMs} ms`;
    }

    async loadProfile() {
        this.isLoading = true;
        this.errorMessage = undefined;
        this.profile = undefined;
        try {
            this.profile = await getUnifiedProfile({ contactId: this.recordId });
        } catch (error) {
            this.errorMessage = this.readableError(error);
        } finally {
            this.isLoading = false;
        }
    }

    readableError(error) {
        if (!error) return 'Unknown error.';
        if (Array.isArray(error.body)) return error.body.map((e) => e.message).join(', ');
        if (error.body?.message) return error.body.message;
        if (typeof error.message === 'string') return error.message;
        return 'Unknown error.';
    }
}
