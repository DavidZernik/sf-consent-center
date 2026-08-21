import { LightningElement, api, track } from 'lwc';
import { highlight, languageFor } from './highlight.js';

/**
 * Slide-out source viewer.
 *
 * The manifest is fetched lazily on first open rather than bundled, so the initial page load
 * stays small: the source of the whole repository is a lot of bytes to ship to someone who
 * might never open the panel.
 */
export default class ViewSourcePanel extends LightningElement {
    @track files = [];
    @track activePath;
    isOpen = false;
    isLoading = false;
    loadError;
    filterTerm = '';

    _manifest;
    _renderedPath;

    /** Opens the panel at a specific file. Called by the shell. */
    @api
    async open(path) {
        this.isOpen = true;
        await this.ensureManifest();
        if (path && this._manifest?.[path]) {
            this.activePath = path;
        } else if (!this.activePath && this.files.length > 0) {
            this.activePath = this.files[0].path;
        }
    }

    @api
    close() {
        this.isOpen = false;
    }

    /* ------------------------------------------------------------------- Getters */

    get panelClass() {
        return this.isOpen ? 'source-panel is-open' : 'source-panel';
    }

    get backdropClass() {
        return this.isOpen ? 'backdrop is-open' : 'backdrop';
    }

    get activeFile() {
        return this.files.find((file) => file.path === this.activePath);
    }

    get activeLineCount() {
        return this.activeFile ? this.activeFile.lineCount : 0;
    }

    get filteredGroups() {
        const term = this.filterTerm.trim().toLowerCase();
        const groups = [];
        for (const file of this.files) {
            if (term && !file.path.toLowerCase().includes(term)) {
                continue;
            }
            let group = groups.find((candidate) => candidate.name === file.group);
            if (!group) {
                group = { name: file.group, key: file.group, files: [] };
                groups.push(group);
            }
            group.files.push({
                ...file,
                key: file.path,
                itemClass: file.path === this.activePath ? 'file-item is-active' : 'file-item'
            });
        }
        return groups;
    }

    get hasResults() {
        return this.filteredGroups.length > 0;
    }

    /* ------------------------------------------------------------------ Handlers */

    handleBackdropClick() {
        this.close();
    }

    handleSelectFile(event) {
        this.activePath = event.currentTarget.dataset.path;
    }

    handleFilter(event) {
        this.filterTerm = event.target.value;
    }

    handleKeydown(event) {
        if (event.key === 'Escape') {
            this.close();
        }
    }

    async handleCopy() {
        const file = this.activeFile;
        if (!file) return;
        try {
            await navigator.clipboard.writeText(file.content);
            this.dispatchEvent(
                new CustomEvent('lightning__showtoast', {
                    bubbles: true,
                    composed: true,
                    detail: { title: 'Copied', message: `${file.name} copied to the clipboard.`, variant: 'success' }
                })
            );
        } catch {
            // Clipboard access can be blocked by permissions policy; failing quietly beats an
            // error the user has no way to act on.
        }
    }

    /* -------------------------------------------------------------------- Loading */

    async ensureManifest() {
        if (this._manifest || this.isLoading) {
            return;
        }
        this.isLoading = true;
        this.loadError = undefined;
        try {
            // Relative fetch: this resolves correctly whether the site is served from a domain
            // root or from a GitHub Pages project subpath.
            const response = await fetch('./sources.json');
            if (!response.ok) {
                throw new Error(`Source manifest returned HTTP ${response.status}`);
            }
            const manifest = await response.json();
            this._manifest = manifest.files;
            this.files = Object.entries(manifest.files).map(([path, entry]) => ({
                path,
                name: path.split('/').pop(),
                group: entry.group,
                lineCount: entry.content.split('\n').length,
                content: entry.content
            }));
        } catch (error) {
            this.loadError = `Could not load the source manifest: ${error.message}`;
        } finally {
            this.isLoading = false;
        }
    }

    /**
     * Paints the highlighted source.
     *
     * Highlighting produces an HTML string, so the container is marked lwc:dom="manual", the
     * supported escape hatch for content LWC did not render itself. The input is repository
     * source read at build time, never user input.
     */
    renderedCallback() {
        if (!this.isOpen || !this.activeFile || this._renderedPath === this.activePath) {
            return;
        }
        const container = this.template.querySelector('[data-code-container]');
        if (!container) {
            return;
        }
        const file = this.activeFile;
        const language = languageFor(file.path);
        const lines = file.content.split('\n');
        const gutter = lines.map((_, index) => index + 1).join('\n');

        // `container` is lwc:dom="manual", the supported way to own a subtree LWC did not
        // render. The content is repository source read at build time, and highlight() escapes
        // <, > and & before emitting; see highlight.test.js for the escaping proofs.
        // eslint-disable-next-line @lwc/lwc/no-inner-html
        container.innerHTML =
            `<pre class="gutter" aria-hidden="true">${gutter}</pre>` +
            `<pre class="code language-${language}"><code>${highlight(file.content, language)}</code></pre>`;

        this._renderedPath = this.activePath;
        container.scrollTop = 0;
    }
}
