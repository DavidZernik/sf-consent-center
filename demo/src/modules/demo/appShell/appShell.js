import { LightningElement, track } from 'lwc';
import { toHash } from '../../../mocks/lightning/navigation.js';
import getConsentDetail from '../../../mocks/apex/getConsentDetail.js';
import { PEOPLE } from '../../../mocks/data/seed.js';

const ROUTES = [
    { id: 'records', label: 'Consent Records', icon: 'standard:contact_list', hash: '#/records' },
    { id: 'unified', label: 'Unified Profile', icon: 'standard:data_mapping', hash: '#/unified' },
    { id: 'sync', label: 'Marketing Cloud Sync', icon: 'standard:data_streams', hash: '#/sync' },
    { id: 'capabilities', label: 'Capability Map', icon: 'standard:solution', hash: '#/capabilities' }
];

/** Contacts that have a Data Cloud unified profile in the fixture. */
const UNIFIED_CONTACTS = ['003Kg000001aA01', '003Kg000001aA04'];

/**
 * Application shell: chrome, routing and the platform services the components expect.
 *
 * Three responsibilities that Lightning Experience would normally own:
 *   1. Routing. NavigationMixin.Navigate emits a window event (see mocks/lightning/navigation.js)
 *      which is translated into a hash route here, so components use the real platform API.
 *   2. Toasts. lightning__showtoast bubbles and is composed, so it surfaces at this boundary and
 *      is handed to the toast host, exactly what the platform does with it.
 *   3. The source panel, which is demo-only and has no platform equivalent.
 *
 * Hash routing rather than the History API because GitHub Pages serves this from a project
 * subpath and has no rewrite rules; a path-based route would 404 on refresh.
 */
export default class AppShell extends LightningElement {
    @track route = { name: 'records', contactId: null };
    @track contactDetail;

    routes = ROUTES;
    searchTerm = '';
    isAppLauncherOpen = false;

    _onHashChange;
    _onNavigate;
    _pendingSourcePath;
    _sourceRequested = false;

    connectedCallback() {
        this._onHashChange = () => this.syncRouteFromHash();
        this._onNavigate = (event) => {
            window.location.hash = toHash(event.detail.pageReference);
        };
        window.addEventListener('hashchange', this._onHashChange);
        window.addEventListener('demo__navigate', this._onNavigate);
        this.syncRouteFromHash();
    }

    disconnectedCallback() {
        window.removeEventListener('hashchange', this._onHashChange);
        window.removeEventListener('demo__navigate', this._onNavigate);
    }

    renderedCallback() {
        this.openSourceIfReady();
    }

    /**
     * Opens the source panel once it is actually in the DOM.
     *
     * Called from both the router and renderedCallback; whichever happens second is the one that
     * succeeds. The flag is cleared on success so a later re-render does not reopen a panel the
     * user has since closed.
     */
    openSourceIfReady() {
        if (!this._sourceRequested) {
            return;
        }
        const panel = this.template.querySelector('demo-view-source-panel');
        if (!panel) {
            return;
        }
        this._sourceRequested = false;
        panel.open(this._pendingSourcePath);
    }

    /* --------------------------------------------------------------------- Routing */

    syncRouteFromHash() {
        const hash = window.location.hash || '#/records';
        const parts = hash.replace(/^#\/?/, '').split('/').filter(Boolean);

        // #/source/<repo path> deep-links straight to a file in the source panel, so a specific
        // class can be shared as a link rather than described as "open the panel and look for".
        if (parts[0] === 'source' && parts.length > 1) {
            this.route = { name: 'capabilities', contactId: null };
            // Queue rather than open directly: this runs from connectedCallback on a cold load,
            // before the first render, so the panel element does not exist yet. renderedCallback
            // drains the queue once it does.
            this._pendingSourcePath = decodeURIComponent(parts.slice(1).join('/'));
            this._sourceRequested = true;
            this.openSourceIfReady();
            return;
        }

        if (parts[0] === 'contact' && parts[1]) {
            this.route = { name: 'contact', contactId: parts[1] };
            this.loadContactDetail(parts[1]);
            return;
        }
        const known = ROUTES.find((candidate) => candidate.id === parts[0]);
        this.route = { name: known ? known.id : 'records', contactId: null };
    }

    async loadContactDetail(contactId) {
        this.contactDetail = undefined;
        try {
            this.contactDetail = await getConsentDetail({ contactId });
        } catch {
            // A contact with no consent records still renders; the panels show their own
            // empty states rather than the page failing as a whole.
            this.contactDetail = undefined;
        }
    }

    /* --------------------------------------------------------------------- Getters */

    get isRecords() {
        return this.route.name === 'records';
    }

    get isContact() {
        return this.route.name === 'contact';
    }

    get isSync() {
        return this.route.name === 'sync';
    }

    get isUnified() {
        return this.route.name === 'unified';
    }

    get isCapabilities() {
        return this.route.name === 'capabilities';
    }

    get navItems() {
        return this.routes.map((item) => ({
            ...item,
            // A contact detail view is still "inside" the records tab.
            isActive: item.id === this.route.name || (this.route.name === 'contact' && item.id === 'records'),
            className:
                item.id === this.route.name || (this.route.name === 'contact' && item.id === 'records')
                    ? 'nav-item is-active'
                    : 'nav-item'
        }));
    }

    get currentTabLabel() {
        if (this.route.name === 'contact') {
            return this.contactDetail?.contactName ?? 'Contact';
        }
        return ROUTES.find((item) => item.id === this.route.name)?.label ?? 'Consent Center';
    }

    get currentTabIcon() {
        if (this.route.name === 'contact') {
            return 'standard:contact';
        }
        return ROUTES.find((item) => item.id === this.route.name)?.icon ?? 'standard:default';
    }

    get contactId() {
        return this.route.contactId;
    }

    get historyEntries() {
        return this.contactDetail?.history ?? [];
    }

    get lifecycleStage() {
        return this.contactDetail?.lifecycleStage;
    }

    get certificateUrl() {
        // On the platform this is /apex/ConsentCertificate?id=<contactId>. Shown as the real
        // URL because the Visualforce page cannot render outside an org.
        return `/apex/ConsentCertificate?id=${this.route.contactId}`;
    }

    /** Contacts with a Data Cloud profile, for the unified-profile picker. */
    get unifiedOptions() {
        return PEOPLE.filter(([id]) => UNIFIED_CONTACTS.includes(id)).map(([id, name, email]) => ({
            label: `${name} (${email})`,
            value: id
        }));
    }

    selectedUnifiedContact = UNIFIED_CONTACTS[0];

    handleUnifiedChange(event) {
        this.selectedUnifiedContact = event.detail.value;
    }

    /* -------------------------------------------------------------------- Handlers */

    handleNavClick(event) {
        event.preventDefault();
        window.location.hash = event.currentTarget.dataset.hash;
    }

    handleBackToList() {
        window.location.hash = '#/records';
    }

    handleGlobalSearch(event) {
        if (event.key !== 'Enter') {
            return;
        }
        // Global search maps onto the list view's own filter.
        this.searchTerm = event.target.value;
        window.location.hash = '#/records';
        this.showToast({
            title: 'Global search',
            message: 'On the platform this runs a SOSL query across Contact, Lead and consent records. See ConsentSelector.searchEverywhere.',
            variant: 'info'
        });
    }

    handleAppLauncher() {
        this.isAppLauncherOpen = !this.isAppLauncherOpen;
    }

    handleCertificateClick() {
        this.showToast({
            title: 'Visualforce PDF',
            message: 'ConsentCertificate.page renders server side with renderAs="pdf", so it only runs inside an org. The page and its controller are in the source panel.',
            variant: 'info',
            mode: 'sticky'
        });
        this.openSource('force-app/main/default/pages/ConsentCertificate.page');
    }

    /** ShowToastEvent bubbles and is composed, so every toast in the app arrives here. */
    handleToast(event) {
        event.stopPropagation();
        this.showToast(event.detail);
    }

    showToast(detail) {
        this.template.querySelector('demo-toast-host')?.show(detail);
    }

    handleViewSource(event) {
        event.stopPropagation();
        const path = event.detail?.path;
        if (path) {
            // Reflect the open file in the URL so it can be copied and shared.
            window.location.hash = `#/source/${encodeURIComponent(path)}`;
            return;
        }
        this.openSource();
    }

    openSource(path) {
        this.template.querySelector('demo-view-source-panel')?.open(path);
    }

    /** Refreshes the audit trail after a save, so the timeline reflects the change. */
    handleConsentChange(event) {
        event.stopPropagation();
        this.loadContactDetail(event.detail.contactId);
    }
}
