/**
 * @description Step 2 — Routing configuration settings. Captures config name,
 *              priority weight, SLA field, capacity, owner field, defer settings,
 *              and busy agent inclusion.
 *
 *              Auto-generates configDevName from configLabel (alphanumeric + underscore).
 *
 *              Fires: CustomEvent('stepdata', { detail: { ...configFields, isValid } })
 *
 * @group UI
 */
import { LightningElement, api } from 'lwc';

import LABEL_CONFIG_NAME from '@salesforce/label/c.URE_WizardConfigNameLabel';
import LABEL_OWNER_FIELD from '@salesforce/label/c.URE_WizardOwnerFieldLabel';
import LABEL_SLA_FIELD from '@salesforce/label/c.URE_WizardSlaFieldLabel';
import LABEL_MAX_CAPACITY from '@salesforce/label/c.URE_WizardMaxCapacityLabel';
import LABEL_INCLUDE_BUSY from '@salesforce/label/c.URE_WizardIncludeBusyLabel';
import LABEL_REQUIRED from '@salesforce/label/c.URE_WizardRequired';

export default class UreWizardStep2Config extends LightningElement {

    label = {
        configName: LABEL_CONFIG_NAME,
        ownerField: LABEL_OWNER_FIELD,
        slaField: LABEL_SLA_FIELD,
        maxCapacity: LABEL_MAX_CAPACITY,
        includeBusy: LABEL_INCLUDE_BUSY,
        required: LABEL_REQUIRED
    };

    @api wizardState = {};

    // Local state for form fields
    configLabel = '';
    configDevName = '';
    ownerFieldApiName = 'OwnerId';
    slaDeadlineField = '';
    maxCapacity = 5;
    priorityWeight = 100;
    assignmentField = '';
    includeBusyAgents = true;
    deferResetField = '';
    deferResetValue = '';

    connectedCallback() {
        // Restore previous state if re-entering this step
        const s = this.wizardState;
        if (s) {
            this.configLabel = s.configLabel || '';
            this.configDevName = s.configDevName || '';
            this.ownerFieldApiName = s.ownerFieldApiName || 'OwnerId';
            this.slaDeadlineField = s.slaDeadlineField || '';
            this.maxCapacity = s.maxCapacity ?? 5;
            this.priorityWeight = s.priorityWeight ?? 100;
            this.assignmentField = s.assignmentField || '';
            this.includeBusyAgents = s.includeBusyAgents ?? true;
            this.deferResetField = s.deferResetField || '';
            this.deferResetValue = s.deferResetValue || '';
        }
    }

    // ─── Public API ─────────────────────────────────────────────────────

    @api
    validate() {
        const inputs = this.template.querySelectorAll('lightning-input');
        let allValid = true;
        inputs.forEach(input => {
            if (!input.reportValidity()) {
                allValid = false;
            }
        });

        if (!this.configLabel?.trim()) {
            allValid = false;
        }
        if (!this.ownerFieldApiName?.trim()) {
            allValid = false;
        }

        return allValid;
    }

    // ─── Event Handlers ─────────────────────────────────────────────────

    handleConfigLabelChange(event) {
        this.configLabel = event.target.value;
        // Auto-generate developer name
        this.configDevName = this.generateDevName(this.configLabel);
        this.fireStepData();
    }

    handleOwnerFieldChange(event) {
        this.ownerFieldApiName = event.target.value;
        this.fireStepData();
    }

    handleSlaFieldChange(event) {
        this.slaDeadlineField = event.target.value;
        this.fireStepData();
    }

    handleMaxCapacityChange(event) {
        this.maxCapacity = parseInt(event.target.value, 10) || 5;
        this.fireStepData();
    }

    handlePriorityWeightChange(event) {
        this.priorityWeight = parseInt(event.target.value, 10) || 100;
        this.fireStepData();
    }

    handleAssignmentFieldChange(event) {
        this.assignmentField = event.target.value;
        this.fireStepData();
    }

    handleIncludeBusyChange(event) {
        this.includeBusyAgents = event.target.checked;
        this.fireStepData();
    }

    handleDeferFieldChange(event) {
        this.deferResetField = event.target.value;
        this.fireStepData();
    }

    handleDeferValueChange(event) {
        this.deferResetValue = event.target.value;
        this.fireStepData();
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    /**
     * @description Generates a valid CMDT DeveloperName from a label.
     *              Alphanumeric + underscore, max 40 chars, no leading digits.
     */
    generateDevName(label) {
        if (!label) return '';
        let devName = label
            .replace(/[^a-zA-Z0-9\s]/g, '')
            .replace(/\s+/g, '_')
            .replace(/^[0-9]+/, '');
        if (devName.length > 40) {
            devName = devName.substring(0, 40);
        }
        return devName;
    }

    fireStepData() {
        const isValid = !!this.configLabel?.trim() && !!this.ownerFieldApiName?.trim();

        this.dispatchEvent(new CustomEvent('stepdata', {
            detail: {
                configLabel: this.configLabel,
                configDevName: this.configDevName,
                ownerFieldApiName: this.ownerFieldApiName,
                slaDeadlineField: this.slaDeadlineField,
                maxCapacity: this.maxCapacity,
                priorityWeight: this.priorityWeight,
                assignmentField: this.assignmentField,
                includeBusyAgents: this.includeBusyAgents,
                deferResetField: this.deferResetField,
                deferResetValue: this.deferResetValue,
                isValid
            }
        }));
    }
}
