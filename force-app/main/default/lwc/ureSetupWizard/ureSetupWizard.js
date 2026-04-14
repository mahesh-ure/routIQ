/**
 * @description Parent orchestrator for the routIQ Setup Wizard. Owns all wizard state,
 *              manages step navigation, and coordinates data flow between 5 child
 *              step components via CustomEvent('stepdata') upward events.
 *
 *              Architecture:
 *              • Parent holds @track wizardState — single source of truth
 *              • Children fire CustomEvent('stepdata', { detail: payload }) on every change
 *              • Parent merges child payload into wizardState via handleStepData()
 *              • Re-entering any step shows previously entered data (state preserved)
 *              • Step 3 conditions and Step 4 skill badges are kept in sync in parent state
 *
 *              Navigation rules:
 *              • Next: only if current step passes validation (child reports isValid)
 *              • Previous: always allowed, preserves all state
 *              • Cancel: confirms with user, resets state
 *              • Finish: deploys config and polls for completion
 *
 *              All user-facing text via Custom Labels (i18n / AppExchange compliant).
 *              No lwc:dom="manual", no innerHTML — XSS safe.
 *
 * @group UI
 */
import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

// ── Custom Labels ────────────────────────────────────────────────────────────
import LABEL_TITLE from '@salesforce/label/c.URE_WizardTitle';
import LABEL_NEXT from '@salesforce/label/c.URE_WizardNext';
import LABEL_PREVIOUS from '@salesforce/label/c.URE_WizardPrevious';
import LABEL_FINISH from '@salesforce/label/c.URE_WizardFinish';
import LABEL_CANCEL from '@salesforce/label/c.URE_WizardCancel';
import LABEL_STEP1 from '@salesforce/label/c.URE_WizardStep1Title';
import LABEL_STEP2 from '@salesforce/label/c.URE_WizardStep2Title';
import LABEL_STEP3 from '@salesforce/label/c.URE_WizardStep3Title';
import LABEL_STEP4 from '@salesforce/label/c.URE_WizardStep4Title';
import LABEL_STEP5 from '@salesforce/label/c.URE_WizardStep5Title';
import LABEL_STEP_OF from '@salesforce/label/c.URE_WizardStepOf';
import LABEL_CONFIG_ACTIVATED from '@salesforce/label/c.URE_WizardConfigActivated';
import LABEL_REQUIRED_FIELDS from '@salesforce/label/c.URE_WizardRequiredFields';

const TOTAL_STEPS = 5;

export default class UreSetupWizard extends LightningElement {

    // ─── Labels ─────────────────────────────────────────────────────────
    label = {
        title: LABEL_TITLE,
        next: LABEL_NEXT,
        previous: LABEL_PREVIOUS,
        finish: LABEL_FINISH,
        cancel: LABEL_CANCEL,
        stepOf: LABEL_STEP_OF
    };

    stepTitles = [LABEL_STEP1, LABEL_STEP2, LABEL_STEP3, LABEL_STEP4, LABEL_STEP5];

    // ─── State ──────────────────────────────────────────────────────────

    currentStep = 1;

    /** @type {Object} Central wizard state — single source of truth */
    @track wizardState = {
        // Step 1
        objectApiName: '',
        objectValidated: false,
        // Step 2
        configLabel: '',
        configDevName: '',
        ownerFieldApiName: 'OwnerId',
        slaDeadlineField: '',
        maxCapacity: 5,
        priorityWeight: 100,
        assignmentField: '',
        includeBusyAgents: true,
        deferResetField: '',
        deferResetValue: '',
        // Step 3
        conditions: [],
        // Step 4
        agents: [],
        // Step 5
        sampleRecordId: '',
        simulateResult: null
    };

    /** Tracks per-step validation state reported by children */
    stepValidity = [false, false, false, false, false];

    // ─── Computed Properties ────────────────────────────────────────────

    get currentStepTitle() {
        return this.stepTitles[this.currentStep - 1] || '';
    }

    get stepProgress() {
        return this.label.stepOf
            .replace('{0}', String(this.currentStep))
            .replace('{1}', String(TOTAL_STEPS));
    }

    get progressPercent() {
        return Math.round((this.currentStep / TOTAL_STEPS) * 100);
    }

    get isFirstStep() {
        return this.currentStep === 1;
    }

    get isLastStep() {
        return this.currentStep === TOTAL_STEPS;
    }

    get showNext() {
        return !this.isLastStep;
    }

    get showPrevious() {
        return !this.isFirstStep;
    }

    get showFinish() {
        return this.isLastStep;
    }

    // Step visibility flags
    get isStep1() { return this.currentStep === 1; }
    get isStep2() { return this.currentStep === 2; }
    get isStep3() { return this.currentStep === 3; }
    get isStep4() { return this.currentStep === 4; }
    get isStep5() { return this.currentStep === 5; }

    // Path indicator items for lightning-progress-indicator
    get pathItems() {
        return this.stepTitles.map((title, index) => ({
            label: title,
            value: String(index + 1),
            class: index + 1 <= this.currentStep ? 'slds-is-complete' : ''
        }));
    }

    // ─── Event Handlers ─────────────────────────────────────────────────

    /**
     * @description Receives data from child step components. Each child fires
     *              CustomEvent('stepdata', { detail: { ...fieldUpdates, isValid } })
     *              on every meaningful user interaction.
     */
    handleStepData(event) {
        const payload = event.detail;
        if (!payload) {
            return;
        }

        // Extract validation state
        if (payload.isValid !== undefined) {
            this.stepValidity[this.currentStep - 1] = payload.isValid;
        }

        // Merge remaining fields into wizard state
        const updatedState = { ...this.wizardState };
        for (const key of Object.keys(payload)) {
            if (key !== 'isValid' && key in updatedState) {
                updatedState[key] = payload[key];
            }
        }
        this.wizardState = updatedState;
    }

    /**
     * @description Advances to the next step after validating the current step.
     *              Queries the child component for validation before proceeding.
     */
    handleNext() {
        if (!this.validateCurrentStep()) {
            return;
        }
        if (this.currentStep < TOTAL_STEPS) {
            this.currentStep += 1;
        }
    }

    /**
     * @description Returns to the previous step. Always allowed — state is preserved.
     */
    handlePrevious() {
        if (this.currentStep > 1) {
            this.currentStep -= 1;
        }
    }

    /**
     * @description Handles the Cancel action. Resets wizard state after confirmation.
     */
    handleCancel() {
        // Reset to initial state
        this.currentStep = 1;
        this.wizardState = {
            objectApiName: '',
            objectValidated: false,
            configLabel: '',
            configDevName: '',
            ownerFieldApiName: 'OwnerId',
            slaDeadlineField: '',
            maxCapacity: 5,
            priorityWeight: 100,
            assignmentField: '',
            includeBusyAgents: true,
            deferResetField: '',
            deferResetValue: '',
            conditions: [],
            agents: [],
            sampleRecordId: '',
            simulateResult: null
        };
        this.stepValidity = [false, false, false, false, false];
    }

    /**
     * @description Handles the Finish/Activate action from Step 5.
     *              The actual deploy logic is in the Step 5 child — this just
     *              receives the completion event.
     */
    handleFinish(event) {
        const detail = event.detail || {};
        if (detail.success) {
            this.dispatchEvent(new ShowToastEvent({
                title: LABEL_TITLE,
                message: detail.message || LABEL_CONFIG_ACTIVATED,
                variant: 'success'
            }));
        }
    }

    // ─── Validation ─────────────────────────────────────────────────────

    /**
     * @description Queries the current step's child component for validation.
     *              Each child implements a validate() method that returns boolean.
     */
    validateCurrentStep() {
        const stepComponent = this.template.querySelector(
            `[data-step="${this.currentStep}"]`
        );

        if (stepComponent && typeof stepComponent.validate === 'function') {
            const isValid = stepComponent.validate();
            this.stepValidity[this.currentStep - 1] = isValid;

            if (!isValid) {
                this.dispatchEvent(new ShowToastEvent({
                    title: this.currentStepTitle,
                    message: LABEL_REQUIRED_FIELDS,
                    variant: 'warning'
                }));
            }
            return isValid;
        }

        // If no validate method, allow navigation
        return true;
    }
}
