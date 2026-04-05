/**
 * @description Step 1 — SObject picker with API name validation. The user enters
 *              an SObject API name and the component validates it against the org
 *              schema via describeSObjectFields. On success, the field list is cached
 *              in wizardState for Step 3.
 *
 *              Fires: CustomEvent('stepdata', { detail: { objectApiName, objectValidated, isValid } })
 *
 * @group UI
 */
import { LightningElement, api } from 'lwc';
import describeSObjectFields from '@salesforce/apex/SetupWizardController.describeSObjectFields';
import getExistingConfigs from '@salesforce/apex/SetupWizardController.getExistingConfigs';

import LABEL_OBJECT_LABEL from '@salesforce/label/c.URE_WizardObjectLabel';
import LABEL_PLACEHOLDER from '@salesforce/label/c.URE_WizardObjectPlaceholder';
import LABEL_HELP from '@salesforce/label/c.URE_WizardObjectHelp';
import LABEL_VALID from '@salesforce/label/c.URE_WizardObjectValid';
import LABEL_INVALID from '@salesforce/label/c.URE_WizardObjectInvalid';
import LABEL_REQUIRED from '@salesforce/label/c.URE_WizardRequired';

export default class UreWizardStep1Object extends LightningElement {

    label = {
        objectLabel: LABEL_OBJECT_LABEL,
        placeholder: LABEL_PLACEHOLDER,
        help: LABEL_HELP,
        valid: LABEL_VALID,
        invalid: LABEL_INVALID,
        required: LABEL_REQUIRED
    };

    @api wizardState = {};

    objectApiName = '';
    isValidating = false;
    validationMessage = '';
    validationVariant = '';
    objectValidated = false;
    existingConfigs = [];

    connectedCallback() {
        // Restore previous state if re-entering this step
        if (this.wizardState?.objectApiName) {
            this.objectApiName = this.wizardState.objectApiName;
            this.objectValidated = this.wizardState.objectValidated || false;
            if (this.objectValidated) {
                this.validationMessage = this.label.valid;
                this.validationVariant = 'success';
            }
        }
        this.loadExistingConfigs();
    }

    // ─── Public API (called by parent) ──────────────────────────────────

    @api
    validate() {
        if (!this.objectApiName || !this.objectApiName.trim()) {
            this.validationMessage = this.label.required;
            this.validationVariant = 'error';
            return false;
        }
        return this.objectValidated;
    }

    // ─── Event Handlers ─────────────────────────────────────────────────

    handleObjectChange(event) {
        this.objectApiName = event.target.value;
        this.objectValidated = false;
        this.validationMessage = '';
        this.fireStepData();
    }

    async handleValidate() {
        const value = this.objectApiName?.trim();
        if (!value) {
            this.validationMessage = this.label.required;
            this.validationVariant = 'error';
            return;
        }

        this.isValidating = true;
        this.validationMessage = '';

        try {
            // describeSObjectFields validates the object and returns fields
            await describeSObjectFields({ sObjectType: value });
            this.objectValidated = true;
            this.validationMessage = this.label.valid;
            this.validationVariant = 'success';
        } catch (error) {
            this.objectValidated = false;
            this.validationMessage = error.body?.message || this.label.invalid;
            this.validationVariant = 'error';
        } finally {
            this.isValidating = false;
            this.fireStepData();
        }
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    async loadExistingConfigs() {
        try {
            this.existingConfigs = await getExistingConfigs();
        } catch (error) {
            this.existingConfigs = [];
        }
    }

    fireStepData() {
        this.dispatchEvent(new CustomEvent('stepdata', {
            detail: {
                objectApiName: this.objectApiName?.trim() || '',
                objectValidated: this.objectValidated,
                isValid: this.objectValidated
            }
        }));
    }

    // ─── Computed ───────────────────────────────────────────────────────

    get hasValidationMessage() {
        return !!this.validationMessage;
    }

    get validationClass() {
        return this.validationVariant === 'success'
            ? 'slds-text-color_success'
            : 'slds-text-color_error';
    }

    get validationIcon() {
        return this.validationVariant === 'success'
            ? 'utility:success'
            : 'utility:error';
    }

    get hasExistingConfigs() {
        return this.existingConfigs && this.existingConfigs.length > 0;
    }
}
