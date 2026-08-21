import { LightningElement, api, track } from 'lwc';

const AUTO_DISMISS_MS = 4500;

const THEME_BY_VARIANT = {
    success: { className: 'slds-notify slds-notify_toast slds-theme_success', icon: 'utility:success' },
    error: { className: 'slds-notify slds-notify_toast slds-theme_error', icon: 'utility:error' },
    warning: { className: 'slds-notify slds-notify_toast slds-theme_warning', icon: 'utility:warning' },
    info: { className: 'slds-notify slds-notify_toast slds-theme_info', icon: 'utility:info' }
};

/**
 * Renders toasts dispatched by components via ShowToastEvent.
 *
 * In an org this is Lightning Experience's job. Reproducing it here is what lets the components
 * keep using the real platform API instead of a demo-specific notification mechanism.
 */
export default class ToastHost extends LightningElement {
    @track toasts = [];
    _nextId = 0;
    _timers = new Map();

    /**
     * Called by the shell when a lightning__showtoast event reaches it.
     *
     * @api is load-bearing, not decoration: without it the method is not exposed on the custom
     * element and the shell's call silently does nothing, so no toast ever appears.
     */
    @api
    show(detail = {}) {
        const id = `toast-${this._nextId++}`;
        const variant = detail.variant || 'info';
        const theme = THEME_BY_VARIANT[variant] || THEME_BY_VARIANT.info;

        this.toasts = [
            ...this.toasts,
            {
                id,
                title: detail.title || '',
                message: detail.message || '',
                className: theme.className,
                icon: theme.icon
            }
        ];

        // mode "sticky" means the user dismisses it, matching the platform behaviour.
        if (detail.mode !== 'sticky') {
            // Tracked in _timers and cleared in disconnectedCallback, which is what the rule
            // is guarding against.
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this._timers.set(id, setTimeout(() => this.dismiss(id), AUTO_DISMISS_MS));
        }
    }

    dismiss(id) {
        clearTimeout(this._timers.get(id));
        this._timers.delete(id);
        this.toasts = this.toasts.filter((toast) => toast.id !== id);
    }

    disconnectedCallback() {
        for (const timer of this._timers.values()) {
            clearTimeout(timer);
        }
        this._timers.clear();
    }

    handleDismiss(event) {
        this.dismiss(event.currentTarget.dataset.id);
    }
}
