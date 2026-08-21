import { LightningElement, track } from 'lwc';
import { groupedCapabilities } from './capabilities.js';

/**
 * Maps each Salesforce capability this app demonstrates to the source that implements it.
 *
 * Every card opens the real file in the View source panel, so a claim can be checked in two
 * clicks rather than taken on faith.
 */
export default class CapabilityMap extends LightningElement {
    @track expandedId;
    activeGroup = 'All';

    get groups() {
        const groups = groupedCapabilities();
        const filtered =
            this.activeGroup === 'All'
                ? groups
                : groups.filter((group) => group.name === this.activeGroup);

        return filtered.map((group) => ({
            ...group,
            items: group.items.map((item) => ({
                ...item,
                isExpanded: item.id === this.expandedId,
                cardClass: item.id === this.expandedId ? 'capability-card is-expanded' : 'capability-card',
                toggleLabel: item.id === this.expandedId ? 'Hide detail' : 'Why it is built this way',
                fileLinks: item.paths.map((path) => ({
                    path,
                    key: path,
                    label: path.split('/').pop()
                }))
            }))
        }));
    }

    get groupOptions() {
        const names = groupedCapabilities().map((group) => group.name);
        return ['All', ...names].map((name) => ({
            name,
            key: name,
            className:
                name === this.activeGroup
                    ? 'slds-button slds-button_brand group-pill'
                    : 'slds-button slds-button_neutral group-pill'
        }));
    }

    get totalCount() {
        return groupedCapabilities().reduce((sum, group) => sum + group.items.length, 0);
    }

    handleGroupChange(event) {
        this.activeGroup = event.currentTarget.dataset.group;
    }

    handleToggleDetail(event) {
        const { id } = event.currentTarget.dataset;
        this.expandedId = this.expandedId === id ? undefined : id;
    }

    /** Asks the shell to open this file in the source panel. */
    handleViewSource(event) {
        this.dispatchEvent(
            new CustomEvent('viewsource', {
                detail: { path: event.currentTarget.dataset.path },
                bubbles: true,
                composed: true
            })
        );
    }

    handleOpenDemo(event) {
        window.location.hash = event.currentTarget.dataset.route;
    }
}
