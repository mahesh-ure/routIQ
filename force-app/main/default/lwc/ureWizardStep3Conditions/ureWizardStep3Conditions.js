/**
 * @description Step 3 — Dynamic condition builder. Loads available fields for the
 *              selected SObject via describeSObjectFields, then allows the user to
 *              add/remove condition rows with field, operator, and value(s).
 *
 *              For picklist fields, values are presented as checkboxes.
 *              For other fields, values are entered as comma-delimited text.
 *
 *              Condition rows are stored as an array in wizardState.conditions.
 *              Each row: { id, fieldApiName, operator, values, valueType }
 *
 *              Fires: CustomEvent('stepdata', { detail: { conditions, isValid } })
 *
 * @group UI
 */
import { LightningElement, api, track } from 'lwc';
import describeSObjectFields from '@salesforce/apex/SetupWizardController.describeSObjectFields';

import LABEL_ADD from '@salesforce/label/c.URE_WizardAddCondition';
import LABEL_REMOVE from '@salesforce/label/c.URE_WizardRemoveCondition';
import LABEL_FIELD from '@salesforce/label/c.URE_WizardFieldLabel';
import LABEL_OPERATOR from '@salesforce/label/c.URE_WizardOperatorLabel';
import LABEL_VALUES from '@salesforce/label/c.URE_WizardValuesLabel';
import LABEL_NO_CONDITIONS from '@salesforce/label/c.URE_WizardNoConditions';

// Supported operators mapped to friendly labels
const OPERATOR_OPTIONS = [
    { label: 'In', value: 'IN' },
    { label: 'Not In', value: 'NOT_IN' },
    { label: 'Equals', value: 'EQUALS' },
    { label: 'Not Equals', value: 'NOT_EQUALS' },
    { label: 'Less Than', value: 'LESS_THAN' },
    { label: 'Greater Than', value: 'GREATER_THAN' },
    { label: 'Less Or Equal', value: 'LESS_OR_EQUAL' },
    { label: 'Greater Or Equal', value: 'GREATER_OR_EQUAL' },
    { label: 'Includes', value: 'INCLUDES' },
    { label: 'Excludes', value: 'EXCLUDES' }
];

let nextConditionId = 1;

export default class UreWizardStep3Conditions extends LightningElement {

    label = {
        add: LABEL_ADD,
        remove: LABEL_REMOVE,
        field: LABEL_FIELD,
        operator: LABEL_OPERATOR,
        values: LABEL_VALUES,
        noConditions: LABEL_NO_CONDITIONS
    };

    @api wizardState = {};

    @track conditions = [];
    @track fieldOptions = [];
    operatorOptions = OPERATOR_OPTIONS;

    isLoadingFields = false;
    fieldDescribeCache = {};

    connectedCallback() {
        // Restore conditions from wizard state
        if (this.wizardState?.conditions?.length) {
            this.conditions = this.wizardState.conditions.map(c => ({
                ...c,
                id: c.id || nextConditionId++
            }));
        }

        // Load fields for the selected object
        if (this.wizardState?.objectApiName) {
            this.loadFields(this.wizardState.objectApiName);
        }
    }

    // ─── Public API ─────────────────────────────────────────────────────

    @api
    validate() {
        // At least one condition required
        if (!this.conditions.length) {
            return false;
        }
        // Every condition must have field, operator, and values
        return this.conditions.every(c =>
            c.fieldApiName && c.operator && c.values
        );
    }

    // ─── Field Loading ──────────────────────────────────────────────────

    async loadFields(sObjectType) {
        this.isLoadingFields = true;
        try {
            const fields = await describeSObjectFields({ sObjectType });
            this.fieldOptions = fields.map(f => ({
                label: `${f.label} (${f.apiName})`,
                value: f.apiName
            }));

            // Cache field metadata for picklist value lookup
            this.fieldDescribeCache = {};
            fields.forEach(f => {
                this.fieldDescribeCache[f.apiName] = f;
            });
        } catch (error) {
            this.fieldOptions = [];
        } finally {
            this.isLoadingFields = false;
        }
    }

    // ─── Event Handlers ─────────────────────────────────────────────────

    handleAddCondition() {
        this.conditions = [
            ...this.conditions,
            {
                id: nextConditionId++,
                fieldApiName: '',
                operator: 'IN',
                values: '',
                valueType: 'String'
            }
        ];
        this.fireStepData();
    }

    handleRemoveCondition(event) {
        const conditionId = parseInt(event.target.dataset.id, 10);
        this.conditions = this.conditions.filter(c => c.id !== conditionId);
        this.fireStepData();
    }

    handleFieldChange(event) {
        const conditionId = parseInt(event.target.dataset.id, 10);
        const fieldApiName = event.detail.value;
        this.conditions = this.conditions.map(c => {
            if (c.id === conditionId) {
                const fieldMeta = this.fieldDescribeCache[fieldApiName];
                return {
                    ...c,
                    fieldApiName,
                    valueType: this.resolveValueType(fieldMeta?.fieldType),
                    values: ''  // Reset values when field changes
                };
            }
            return c;
        });
        this.fireStepData();
    }

    handleOperatorChange(event) {
        const conditionId = parseInt(event.target.dataset.id, 10);
        const operator = event.detail.value;
        this.conditions = this.conditions.map(c => {
            if (c.id === conditionId) {
                return { ...c, operator };
            }
            return c;
        });
        this.fireStepData();
    }

    handleValuesChange(event) {
        const conditionId = parseInt(event.target.dataset.id, 10);
        const values = event.target.value;
        this.conditions = this.conditions.map(c => {
            if (c.id === conditionId) {
                return { ...c, values };
            }
            return c;
        });
        this.fireStepData();
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    resolveValueType(fieldType) {
        if (!fieldType) return 'String';
        const numberTypes = new Set(['DOUBLE', 'INTEGER', 'CURRENCY', 'PERCENT']);
        if (numberTypes.has(fieldType)) return 'Number';
        if (fieldType === 'BOOLEAN') return 'Boolean';
        if (fieldType === 'DATE') return 'Date';
        if (fieldType === 'DATETIME') return 'DateTime';
        return 'String';
    }

    fireStepData() {
        this.dispatchEvent(new CustomEvent('stepdata', {
            detail: {
                conditions: this.conditions.map(c => ({
                    id: c.id,
                    fieldApiName: c.fieldApiName,
                    operator: c.operator,
                    values: c.values,
                    valueType: c.valueType
                })),
                isValid: this.conditions.length > 0
                    && this.conditions.every(c => c.fieldApiName && c.operator && c.values)
            }
        }));
    }

    // ─── Computed ───────────────────────────────────────────────────────

    get hasConditions() {
        return this.conditions.length > 0;
    }

    get hasFields() {
        return this.fieldOptions.length > 0;
    }
}
