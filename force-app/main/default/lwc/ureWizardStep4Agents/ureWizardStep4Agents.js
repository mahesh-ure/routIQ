/**
 * @description Step 4 — Agent selection with capability badge derivation from Step 3
 *              conditions. Loads active agents and allows the user to select which
 *              agents will receive routed records.
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
import getActiveAgents from '@salesforce/apex/SetupWizardController.getActiveAgents';

import LABEL_SELECT_AGENTS from '@salesforce/label/c.URE_WizardSelectAgents';
import LABEL_NO_AGENTS from '@salesforce/label/c.URE_WizardNoAgents';

export default class UreWizardStep4Agents extends LightningElement {

    label = {
        selectAgents: LABEL_SELECT_AGENTS,
        noAgents: LABEL_NO_AGENTS
    };

    @api wizardState = {};

    @track agents = [];
    @track allAgents = [];  // Unfiltered full list
    @track selectedAgentIds = new Set();
    @track profileOptions = [];
    @track managerOptions = [];
    selectedProfileId = '';
    selectedManagerId = '';
    isLoading = false;
    error = '';

    connectedCallback() {
        // Restore previously selected agents
        if (this.wizardState?.agents?.length) {
            this.selectedAgentIds = new Set(
                this.wizardState.agents.map(a => a.userId)
            );
        }
        this.loadAgents();
    }

    // ─── Public API ─────────────────────────────────────────────────────

    @api
    validate() {
        return this.selectedAgentIds.size > 0;
    }

    // ─── Data Loading ───────────────────────────────────────────────────

    async loadAgents() {
        this.isLoading = true;
        this.error = '';
        try {
            const result = await getActiveAgents();
            this.allAgents = result.map(agent => ({
                ...agent,
                selected: this.selectedAgentIds.has(agent.userId),
                capacityDisplay: `${agent.currentLoad}/${agent.maxCapacity}`
            }));
            this.agents = this.allAgents;
            this.buildFilterOptions();
        } catch (err) {
            this.error = err.body?.message || 'Failed to load agents.';
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
        const newSet = new Set();
        this.agents.forEach(a => newSet.add(a.userId));
        this.selectedAgentIds = newSet;
        this.agents = this.agents.map(a => ({ ...a, selected: true }));
        this.fireStepData();
    }

    handleDeselectAll() {
        this.selectedAgentIds = new Set();
        this.agents = this.agents.map(a => ({ ...a, selected: false }));
        this.fireStepData();
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    fireStepData() {
        const selectedAgents = this.agents
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
        return `${this.selectedCount} of ${this.totalCount} agents selected`;
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
