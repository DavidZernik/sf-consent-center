import { LightningElement, api } from 'lwc';

/**
 * Explains how consent resolved across a unified profile.
 *
 * The value here is not the answer, it is the reasoning. "Opted out" on its own invites the
 * question "says who?", so each channel shows which sources contributed and which rule decided
 * the outcome. That is the view someone actually needs during a compliance conversation.
 */
export default class ConsentResolutionPanel extends LightningElement {
    _resolved = [];
    _sources = [];

    @api
    get resolved() {
        return this._resolved;
    }
    set resolved(value) {
        this._resolved = Array.isArray(value) ? value : [];
    }

    @api
    get sources() {
        return this._sources;
    }
    set sources(value) {
        this._sources = Array.isArray(value) ? value : [];
    }

    get hasData() {
        return this._resolved.length > 0;
    }

    get conflictCount() {
        return this._resolved.filter((channel) => channel.isConflicted).length;
    }

    get hasConflicts() {
        return this.conflictCount > 0;
    }

    get conflictLabel() {
        const count = this.conflictCount;
        return `${count} ${count === 1 ? 'channel has' : 'channels have'} conflicting source records`;
    }

    /** Joins each resolved channel to the source rows that fed it. */
    get channels() {
        return this._resolved.map((channel) => {
            const contributing = this._sources
                .filter((source) => source.channel === channel.channel)
                .map((source) => ({
                    ...source,
                    key: `${source.sourceRecordId}-${source.channel}`,
                    statusLabel: source.optIn ? 'Opted in' : 'Opted out',
                    // The dissenting source is the interesting one, so mark it.
                    isDecisive: !channel.optIn && !source.optIn,
                    statusClass: source.optIn
                        ? 'slds-text-color_success'
                        : 'slds-text-color_error slds-text-title_bold'
                }));

            return {
                ...channel,
                key: channel.channel,
                statusLabel: channel.optIn ? 'Opted in' : 'Opted out',
                statusClass: channel.optIn
                    ? 'slds-badge slds-theme_success'
                    : 'slds-badge slds-theme_error',
                rowClass: channel.isConflicted ? 'channel-block conflicted' : 'channel-block',
                contributing
            };
        });
    }
}
