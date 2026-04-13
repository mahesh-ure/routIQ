/**
 * @description Step 4 — Agent selection with capability badge derivation from Step 3
 *              conditions. Searches ALL active Salesforce Users (not just existing
 *              Agent__c records) so the wizard works on a fresh install.
 *
 *              Skill badges are derived from Step 3 conditions: each condition's
 *              fieldApiName becomes a skill dimension, and the condition's values
 *              become the expected skill values.
 *
 *              Fires: CustomEvent('stepdata', { detail: { agents, isValid } })
 *
 * @group UI
 */
import { LightningElement, api, track } from 'lwc';
import searchAvailableUsers from '@salesforce/apex/SetupWizardController.searchAvailableUsers';

import LABEL_SELECT_AGENTS from '@salesforce/label/c.URE_WizardSelectAgents';
import LABEL_NO_AGENTS from '@salesforce/label/c.URE_WizardNoAgents';
import LABEL_SEARCH_USERS from '@salesforce/label/c.URE_WizardSearchUsers';

const SEARCH_DELAY_MS = 300;

export default class UreWizardStep4Agents extends LightningElement {

    label = {
        selectAgents: LABEL_SELECT_AGENTS,
        noAgents: LABEL_NO_AGENTS,
        searchUsers: LABEL_SEARCH_USERS
    };

    @api wizardState = {};

    @track agents = [];
    @track allAgents = [];  // Unfiltered full list
    @track selectedAgentIds = new Set();
    @track profileOptions = [];
    @track managerOptions = [];
    selectedProfileId = '';
    selectedManagerId = '';
    searchTerm = '';
    isLoading = false;
    error = '';
    _searchTimer;

    connectedCallback() {
        // Restore previously selected agents
        if (this.wizardState?.agents?.length) {
            this.selectedAgentIds = new Set(
                this.wizardState.agents.map(a => a.userId)
            );
        }
        this.loadUsers('');
    }

    // ─── Public API ─────────────────────────────────────────────────────

    @api
    validate() {
        return this.selectedAgentIds.size > 0;
    }

    // ─── Data Loading ───────────────────────────────────────────────────

    async loadUsers(searchTerm) {
        this.isLoading = true;
        this.error = '';
        try {
            const result = await searchAvailableUsers({ searchTerm });
            this.allAgents = result.map(agent => ({
                ...agent,
                selected: this.selectedAgentIds.has(agent.userId),
                capacityDisplay: agent.agentId
                    ? `${agent.currentLoad}/${agent.maxCapacity}`
                    : 'New',
                isExistingAgent: !!agent.agentId
            }));
            this.agents = this.allAgents;
            this.buildFilterOptions();
        } catch (err) {
            this.error = err.body?.message || 'Failed to load users.';
            this.allAgents = [];
            this.agents = [];
        } finally {
            this.isLoading = false;
        }
    }

    /**
     * @description Build unique profile and manager filter options from loaded agents.
     */
    buildFilterOptions() {
        const profileSet = new Set();
        const managerSet = new Set();

        this.allAgents.forEach(agent => {
            if (agent.profileName) {
                profileSet.add(JSON.stringify({ id: agent.profileId, name: agent.profileName }));
            }
            if (agent.managerName) {
                managerSet.add(JSON.stringify({ id: agent.managerId, name: agent.managerName }));
            }
        });

        this.profileOptions = [
            { label: '-- All Profiles --', value: '' },
            ...Array.from(profileSet)
                .map(p => {
                    const obj = JSON.parse(p);
                    return { label: obj.name, value: obj.id };
                })
                .sort((a, b) => a.label.localeCompare(b.label))
        ];

        this.managerOptions = [
            { label: '-- All Managers --', value: '' },
            ...Array.from(managerSet)
                .map(m => {
                    const obj = JSON.parse(m);
                    return { label: obj.name, value: obj.id };
                })
                .sort((a, b) => a.label.localeCompare(b.label))
        ];
    }

    // ─── Search ────────────────────────────────────────────────────────

    handleSearchChange(event) {
        this.searchTerm = event.target.value;

        // Debounce search calls
        if (this._searchTimer) {
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            clearTimeout(this._searchTimer);
        }
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._searchTimer = setTimeout(() => {
            this.loadUsers(this.searchTerm);
        }, SEARCH_DELAY_MS);
    }

    /**
     * @description Apply profile filter to agent list.
     */
    handleProfileFilterChange(event) {
        this.selectedProfileId = event.detail.value;
        this.applyFilters();
    }

    /**
     * @description Apply manager filter to agent list.
     */
    handleManagerFilterChange(event) {
        this.selectedManagerId = event.detail.value;
        this.applyFilters();
    }

    /**
     * @description Apply all active filters to agents list.
     */
    applyFilters() {
        let filtered = this.allAgents;

        if (this.selectedProfileId) {
            filtered = filtered.filter(a => a.profileId === this.selectedProfileId);
        }

        if (this.selectedManagerId) {
            filtered = filtered.filter(a => a.managerId === this.selectedManagerId);
        }

        // Restore selected state
        this.agents = filtered.map(a => ({
            ...a,
            selected: this.selectedAgentIds.has(a.userId)
        }));
    }

    // ─── Event Handlers ─────────────────────────────────────────────────

    handleAgentToggle(event) {
        const userId = event.target.dataset.userid;
        const checked = event.target.checked;

        // Update selected set (immutable pattern for reactivity)
        const newSet = new Set(this.selectedAgentIds);
        if (checked) {
            newSet.add(userId);
        } else {
            newSet.delete(userId);
        }
        this.selectedAgentIds = newSet;

        // Update display state
        this.agents = this.agents.map(a => ({
            ...a,
            selected: this.selectedAgentIds.has(a.userId)
        }));

        this.fireStepData();
    }

    handleSelectAll() {
        const newSet = new Set(this.selectedAgentIds);
        this.agents.forEach(a => newSet.add(a.userId));
        this.selectedAgentIds = newSet;
        this.agents = this.agents.map(a => ({ ...a, selected: true }));
        this.fireStepData();
    }

    handleDeselectAll() {
        // Only deselect agents currently visible (filtered)
        const newSet = new Set(this.selectedAgentIds);
        this.agents.forEach(a => newSet.delete(a.userId));
        this.selectedAgentIds = newSet;
        this.agents = this.agents.map(a => ({ ...a, selected: false }));
        this.fireStepData();
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    fireStepData() {
        // Build selected agents from ALL agents (not just visible)
        const allKnown = [...this.allAgents];
        const selectedAgents = allKnown
            .filter(a => this.selectedAgentIds.has(a.userId))
            .map(a => ({
                userId: a.userId,
                skillValues: this.deriveSkillValues()
            }));

        this.dispatchEvent(new CustomEvent('stepdata', {
            detail: {
                agents: selectedAgents,
                isValid: selectedAgents.length > 0
            }
        }));
    }

    /**
     * @description Derives skill badge values from Step 3 conditions.
     *              Each condition's values become skill requirements.
     */
    deriveSkillValues() {
        const conditions = this.wizardState?.conditions || [];
        const skills = [];
        conditions.forEach(c => {
            if (c.fieldApiName && c.values) {
                skills.push(c.values);
            }
        });
        return skills;
    }

    // ─── Computed ───────────────────────────────────────────────────────

    get hasAgents() {
        return this.agents.length > 0;
    }

    get hasError() {
        return !!this.error;
    }

    get selectedCount() {
        return this.selectedAgentIds.size;
    }

    get totalCount() {
        return this.agents.length;
    }

    get selectionSummary() {
        return `${this.selectedCount} of ${this.totalCount} users selected`;
    }

    /**
     * @description Derives capability badges from Step 3 conditions for display.
     */
    get skillBadges() {
        const conditions = this.wizardState?.conditions || [];
        return conditions
            .filter(c => c.fieldApiName && c.values)
            .map(c => ({
                key: c.fieldApiName,
                label: `${c.fieldApiName}: ${c.values}`
            }));
    }

    get hasSkillBadges() {
        return this.skillBadges.length > 0;
    }
}
