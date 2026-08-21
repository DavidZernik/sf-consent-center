// Synthetic shadow MUST be imported before the engine.
//
// Lightning Experience runs LWC in synthetic shadow, not native. That is not a detail: the SLDS
// stylesheet is a document-level stylesheet, and native shadow roots block it, so every slds-*
// class used inside a component silently stops applying. Matching the platform here is both more
// faithful and the reason the layout works at all.
import '@lwc/synthetic-shadow';
import { createElement } from 'lwc';
import AppShell from 'demo/appShell';
import { seedStore } from './mocks/apex/seedStore.js';

/**
 * Demo entry point.
 *
 * Seeds the in-memory store, then mounts the shell. Nothing else: every behaviour beyond this
 * point lives in a Lightning Web Component.
 */
seedStore();

if (!window.location.hash) {
    window.location.hash = '#/records';
}

const app = createElement('demo-app-shell', { is: AppShell });
document.getElementById('main').appendChild(app);

// Remove the pre-hydration splash once the first paint has happened.
requestAnimationFrame(() => {
    document.getElementById('boot')?.remove();
});
