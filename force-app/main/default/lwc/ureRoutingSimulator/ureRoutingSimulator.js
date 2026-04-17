/**
 * @description Standalone routing simulator component. Allows admins to test any
 *              routing configuration against any record before activating it.
 *
 *              Workflow:
 *              1. Select a config from picklist (getActiveConfigs)
 *              2. Enter a sample record ID
 *              3. Click Simulate (calls simulateRouting with dryRun=true)
 *              4. View results: matched agent, all condition traces, reason summary
 *              5. No data is modified — pure read-only test
 *
 *              Result Display:
 *              - Success: agent name, candidate count, lock retries (if any)
 *              - No match: reason and per-condition pass/fail with actual values
 *              - Traces table: field, operator, expected, actual, pass/fail
 *
 *              Integration:
 *              - Can be embedded in Setup Wizard Step 5 (currently used)
 *              - Can be added as a standalone app panel
 *              - Can be accessed from Settings page
 *
 * @group UI
 */
import { LightningElement, track } from 'lwc';
import getActiveConfigs from '@salesforce/apex/RoutingSimulatorController.getActiveConfigs';
import simulateRouting from '@salesforce/apex/RoutingSimulatorController.simulateRouting';

import LABEL_CONFIG_SELECT from '@salesforce/label/c.URE_WizardConfigNameLabel';
import LABEL_RECORD_ID from '@salesforce/label/c.URE_WizardRecordIdLabel';
import LABEL_RECORD_HELP from '@salesforce/label/c.URE_WizardRecordIdHelp';
import LABEL_SIMULATE from '@salesforce/label/c.URE_WizardSimulate';
import LABEL_SIM_RESULT from '@salesforce/label/c.URE_WizardSimulationResult';
import LABEL_TRACES from '@salesforce/label/c.URE_WizardConditionTraces';
import LABEL_SIMULATING from '@salesforce/label/c.URE_WizardSimulating';
import LABEL_SAMPLE_ERROR from '@salesforce/label/c.URE_WizardSampleRecordError';
import LABEL_SIM_FAILED from '@salesforce/label/c.URE_WizardSimulationFailed';

export default class UreRoutingSimulator extends LightningElement {

    label = {
        configSelect: LABEL_CONFIG_SELECT,
        recordId: LABEL_RECORD_ID,
        recordHelp: LABEL_RECORD_HELP,
        simulate: LABEL_SIMULATE,
        simResult: LABEL_SIM_RESULT,
        traces: LABEL_TRACES,
        simulating: LABEL_SIMULATING
    };

    // Configs picklist
    @track availableConfigs = [];
    selectedConfigDevName = '';
    configsLoading = false;
    configsError = '';

    // Simulation state
    recordId = '';
    @track simulateResult = null;
    isSimulating = false;
    simulateError = '';

    connectedCallback() {
        this.loadConfigs();
    }

    // ─── Configs Loading ────────────────────────────────────────────────

    async loadConfigs() {
        this.configsLoading = true;
        this.configsError = '';
        this.availableConfigs = [];

        try {
            const configs = await getActiveConfigs();
            this.availableConfigs = configs.map(c => ({
                label: c.label,
                value: c.developerName,
                apiName: c.objectApiName
            }));
        } catch (error) {
            this.configsError = 'Failed to load configurations. Try refreshing the page.';
        } finally {
            this.configsLoading = false;
        }
    }

    // ─── Config Selection ───────────────────────────────────────────────

    handleConfigChange(event) {
        this.selectedConfigDevName = event.detail.value;
        this.simulateResult = null;
        this.simulateError = '';
    }

    // ─── Record ID Input ────────────────────────────────────────────────

    handleRecordIdChange(event) {
        this.recordId = event.target.value;
        this.simulateResult = null;
        this.simulateError = '';
    }

    // ─── Simulate ───────────────────────────────────────────────────────

    async handleSimulate() {
        // Validation
        if (!this.selectedConfigDevName?.trim()) {
            this.simulateError = 'Please select a routing configuration.';
            return;
        }

        if (!this.recordId?.trim()) {
            this.simulateError = LABEL_SAMPLE_ERROR;
            return;
        }

        // Execute simulation
        this.isSimulating = true;
        this.simulateResult = null;
        this.simulateError = '';

        try {
            const result = await simulateRouting({
                recordId: this.recordId.trim(),
                configDeveloperName: this.selectedConfigDevName
            });
            this.simulateResult = result;
        } catch (error) {
            this.simulateError = error.body?.message || LABEL_SIM_FAILED;
        } finally {
            this.isSimulating = false;
        }
    }

    // ─── Computed Properties ────────────────────────────────────────────

    get hasConfigs() {
        return this.availableConfigs && this.availableConfigs.length > 0;
    }

    get noConfigs() {
        return !this.hasConfigs;
    }

    get hasConfigError() {
        return !!this.configsError;
    }

    get hasSimulateResult() {
        return this.simulateResult !== null;
    }

    get simulateSuccess() {
        return this.simulateResult?.success === true;
    }

    get simulateFailed() {
        return this.simulateResult?.success === false;
    }

    get hasSimulateError() {
        return !!this.simulateError;
    }

    get hasTraces() {
        return this.conditionTraces.length > 0;
    }

    get noTraces() {
        return this.conditionTraces.length === 0;
    }

    get reasonSummary() {
        return this.simulateResult?.reasonSummary || '';
    }

    get conditionTraces() {
        return this.simulateResult?.conditionTraces || [];
    }

    get hasTraces() {
        return this.conditionTraces.length > 0;
    }

    get resultIcon() {
        return this.simulateSuccess ? 'utility:success' : 'utility:warning';
    }

    get resultVariant() {
        return this.simulateSuccess ? 'success' : 'warning';
    }

    get resultTitle() {
        return this.simulateSuccess ? 'Match Found' : 'No Match';
    }

    get resultErrorMessage() {
        return this.simulateResult?.errorMessage || '';
    }

    get isSimulateDisabled() {
        return this.isSimulating || !this.hasConfigs || !this.selectedConfigDevName;
    }

    get configOptions() {
        return this.availableConfigs.map(c => ({
            label: c.label,
            value: c.value
        }));
    }
}
