import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getConsentDetail from '@salesforce/apex/ConsentService.getConsentDetail';
import savePreferences from '@salesforce/apex/ConsentService.savePreferences';

const CHANNELS = ['Email', 'SMS', 'Push', 'Direct Mail'];

const CHANNEL_META = {
    Email: { icon: 'utility:email', description: 'Newsletters, product news and campaign sends.' },
    SMS: { icon: 'utility:sms', description: 'Order updates and time-sensitive offers.' },
    Push: { icon: 'utility:notification', description: 'Mobile app notifications.' },
    'Direct Mail': { icon: 'utility:mail', description: 'Printed catalogues and postcards.' }
};

/**
 * Channel-level consent editor for one contact.
 *
 * Holds a working copy of the preferences so the user can toggle several channels and save
 * once. Only the differences against the loaded state are submitted, which keeps the audit
 * trail meaningful — Apex would skip no-op rows anyway, but sending them would be sloppy.
 */
export default class ConsentPreferencePanel extends LightningElement {
    _recordId;

    /**
     * Contact whose preferences are being edited. On a record page this is supplied by the
     * page; in an app page it is passed in by the parent.
     */
    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
        if (value) {
            this.loadDetail();
        }
    }

    /** Recorded on the audit trail so a change can be traced back to the surface that made it. */
    @api source = 'Service Console';

    @track channels = [];
    detail;
    isLoading = false;
    isSaving = false;
    errorMessage;

    _loadedOptInByChannel = {};

    /* ------------------------------------------------------------------- Getters */

    get contactName() {
        return this.detail?.contactName ?? '';
    }

    get email() {
        return this.detail?.email ?? '';
    }

    get lifecycleStage() {
        return this.detail?.lifecycleStage;
    }

    get isDirty() {
        return this.changedChannels.length > 0;
    }

    get isSaveDisabled() {
        return !this.isDirty || this.isSaving || this.isLoading;
    }

    get changedChannels() {
        return this.channels.filter((c) => c.optIn !== this._loadedOptInByChannel[c.channel]);
    }

    get dirtyLabel() {
        const count = this.changedChannels.length;
        if (count === 0) return 'No unsaved changes';
        return `${count} unsaved ${count === 1 ? 'change' : 'changes'}`;
    }

    get dirtyLabelClass() {
        return this.isDirty
            ? 'slds-text-body_small slds-text-color_warning'
            : 'slds-text-body_small slds-text-color_weak';
    }

    /* ------------------------------------------------------------------ Handlers */

    handleToggle(event) {
        const { channel } = event.target.dataset;
        const optIn = event.target.checked;
        this.channels = this.channels.map((c) => (c.channel === channel ? { ...c, optIn } : c));
    }

    handleReset() {
        this.channels = this.channels.map((c) => ({
            ...c,
            optIn: this._loadedOptInByChannel[c.channel]
        }));
    }

    async handleSave() {
        const changes = this.changedChannels.map(({ channel, optIn }) => ({ channel, optIn }));
        if (changes.length === 0) {
            return;
        }

        this.isSaving = true;
        try {
            // Apex takes the payload as a JSON string: Lightning cannot marshal a list of
            // Apex inner-class instances on the way in, only on the way out.
            const detail = await savePreferences({
                contactId: this.recordId,
                changesJson: JSON.stringify(changes),
                source: this.source
            });
            this.applyDetail(detail);
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Preferences saved',
                    message: `${changes.length} ${changes.length === 1 ? 'channel' : 'channels'} updated and queued for Marketing Cloud.`,
                    variant: 'success'
                })
            );
            // Let a parent refresh anything derived from consent (sync console, unified profile).
            this.dispatchEvent(new CustomEvent('consentchange', {
                detail: { contactId: this.recordId, changes },
                bubbles: true,
                composed: true
            }));
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Could not save preferences',
                    message: this.readableError(error),
                    variant: 'error',
                    mode: 'sticky'
                })
            );
        } finally {
            this.isSaving = false;
        }
    }

    /* ------------------------------------------------------------------- Loading */

    async loadDetail() {
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            const detail = await getConsentDetail({ contactId: this.recordId });
            this.applyDetail(detail);
        } catch (error) {
            this.errorMessage = this.readableError(error);
        } finally {
            this.isLoading = false;
        }
    }

    /**
     * Projects the Apex response onto the full channel list.
     *
     * A contact who has never expressed a preference on a channel has no row for it, so the
     * list is built from the known channels rather than from whatever Apex returned. Otherwise
     * new channels would be invisible and unsettable.
     */
    applyDetail(detail) {
        this.detail = detail;
        const byChannel = new Map((detail?.preferences ?? []).map((p) => [p.channel, p]));

        this.channels = CHANNELS.map((channel) => {
            const existing = byChannel.get(channel);
            return {
                channel,
                optIn: existing?.optIn ?? false,
                syncStatus: existing?.syncStatus ?? 'Never synced',
                lastChanged: existing?.lastChanged,
                hasRecord: Boolean(existing),
                icon: CHANNEL_META[channel].icon,
                description: CHANNEL_META[channel].description
            };
        });

        this._loadedOptInByChannel = this.channels.reduce((acc, c) => {
            acc[c.channel] = c.optIn;
            return acc;
        }, {});
    }

    readableError(error) {
        if (!error) return 'Unknown error.';
        if (Array.isArray(error.body)) return error.body.map((e) => e.message).join(', ');
        if (error.body?.message) return error.body.message;
        if (typeof error.message === 'string') return error.message;
        return 'Unknown error.';
    }
}
