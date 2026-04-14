/**
 * @description Step 5 — Simulate routing with dryRun and activate via CMDT deploy.
 *
 *              Simulate: calls SetupWizardController.simulateRouting() with a sample
 *              record ID. Displays reasonSummary and conditionTraces from the dry-run.
 *
 *              Activate: calls SetupWizardController.deployConfig() which enqueues
 *              CMDT deployment. Polls getDeployStatus() every 3 seconds until complete.
 *
 *              Fires:
 *              - CustomEvent('stepdata', { detail: { sampleRecordId, isValid } })
 *              - CustomEvent('finish', { detail: { success, message } })
 *
 * @group UI
 */
import { LightningElement, api, track } from 'lwc';
import simulateRouting from '@salesforce/apex/SetupWizardController.simulateRouting';
import deployConfig from '@salesforce/apex/SetupWizardController.deployConfig';
import getDeployStatus from '@salesforce/apex/SetupWizardController.getDeployStatus';

import LABEL_SIMULATE from '@salesforce/label/c.URE_WizardSimulate';
import LABEL_RECORD_ID from '@salesforce/label/c.URE_WizardRecordIdLabel';
import LABEL_RECORD_HELP from '@salesforce/label/c.URE_WizardRecordIdHelp';
import LABEL_SIM_RESULT from '@salesforce/label/c.URE_WizardSimulationResult';
import LABEL_TRACES from '@salesforce/label/c.URE_WizardConditionTraces';
import LABEL_DEPLOYING from '@salesforce/label/c.URE_WizardDeploying';
import LABEL_SUCCESS from '@salesforce/label/c.URE_WizardDeploySuccess';
import LABEL_FAILED from '@salesforce/label/c.URE_WizardDeployFailed';
import LABEL_SIMULATING from '@salesforce/label/c.URE_WizardSimulating';
import LABEL_ACTIVATE from '@salesforce/label/c.URE_WizardFinish';
import LABEL_SAMPLE_ERROR from '@salesforce/label/c.URE_WizardSampleRecordError';
import LABEL_SIM_FAILED from '@salesforce/label/c.URE_WizardSimulationFailed';
import LABEL_DEPLOY_START_FAILED from '@salesforce/label/c.URE_WizardDeployStartFailed';
import LABEL_DEPLOY_ERROR from '@salesforce/label/c.URE_WizardDeployError';
import LABEL_DEPLOY_TIMEOUT from '@salesforce/label/c.URE_WizardDeployTimeout';
import LABEL_DEPLOY_CONN_LOST from '@salesforce/label/c.URE_WizardDeployConnectionLost';

const POLL_INTERVAL_MS = 3000;
const MAX_POLL_ATTEMPTS = 60; // 3 min max

export default class UreWizardStep5Simulate extends LightningElement {

    label = {
        simulate: LABEL_SIMULATE,
        recordId: LABEL_RECORD_ID,
        recordHelp: LABEL_RECORD_HELP,
        simResult: LABEL_SIM_RESULT,
        traces: LABEL_TRACES,
        deploying: LABEL_DEPLOYING,
        success: LABEL_SUCCESS,
        failed: LABEL_FAILED,
        simulating: LABEL_SIMULATING,
        activate: LABEL_ACTIVATE
    };

    @api wizardState = {};

    sampleRecordId = '';
    @track simulateResult = null;
    isSimulating = false;
    simulateError = '';

    isDeploying = false;
    deploymentId = '';
    deployStatus = '';
    deployError = '';
    deploySuccess = false;
    pollTimer = null;
    pollAttempts = 0;

    connectedCallback() {
        if (this.wizardState?.sampleRecordId) {
            this.sampleRecordId = this.wizardState.sampleRecordId;
        }
    }

    disconnectedCallback() {
        this.clearPollTimer();
    }

    // ─── Public API ─────────────────────────────────────────────────────

    @api
    validate() {
        // Step 5 validation: simulate is optional, but the step is always valid
        // as long as the user can attempt activation
        return true;
    }

    // ─── Simulate ───────────────────────────────────────────────────────

    handleRecordIdChange(event) {
        this.sampleRecordId = event.target.value;
        this.simulateResult = null;
        this.simulateError = '';
        this.fireStepData();
    }

    async handleSimulate() {
        if (!this.sampleRecordId?.trim()) {
            this.simulateError = LABEL_SAMPLE_ERROR;
            return;
        }

        this.isSimulating = true;
        this.simulateResult = null;
        this.simulateError = '';

        try {
            const result = await simulateRouting({
                recordId: this.sampleRecordId.trim(),
                configDevName: this.wizardState?.configDevName || ''
            });
            this.simulateResult = result;
        } catch (error) {
            this.simulateError = error.body?.message || LABEL_SIM_FAILED;
        } finally {
            this.isSimulating = false;
        }
    }

    // ─── Deploy / Activate ──────────────────────────────────────────────

    async handleActivate() {
        this.isDeploying = true;
        this.deployError = '';
        this.deployStatus = this.label.deploying;

        try {
            const stateJson = JSON.stringify(this.wizardState);
            const result = await deployConfig({ wizardStateJson: stateJson });

            if (result.success && result.deploymentId) {
                this.deploymentId = result.deploymentId;
                this.deployStatus = this.label.deploying;

                if (result.agentWarning) {
                    this.deployError = result.agentWarning;
                }

                // Start polling for deployment completion
                this.pollAttempts = 0;
                this.startPollTimer();
            } else {
                this.isDeploying = false;
                this.deployError = result.message || LABEL_DEPLOY_START_FAILED;
            }
        } catch (error) {
            this.isDeploying = false;
            this.deployError = error.body?.message || LABEL_DEPLOY_ERROR;
        }
    }

    // ─── Polling ────────────────────────────────────────────────────────

    startPollTimer() {
        this.clearPollTimer();
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.pollTimer = setInterval(() => {
            this.pollDeployment();
        }, POLL_INTERVAL_MS);
    }

    clearPollTimer() {
        if (this.pollTimer) {
            clearInterval(this.pollTimer);
            this.pollTimer = null;
        }
    }

    async pollDeployment() {
        this.pollAttempts++;

        if (this.pollAttempts > MAX_POLL_ATTEMPTS) {
            this.clearPollTimer();
            this.isDeploying = false;
            this.deployError = LABEL_DEPLOY_TIMEOUT;
            return;
        }

        try {
            const status = await getDeployStatus({
                deploymentId: this.deploymentId
            });

            if (status.done) {
                this.clearPollTimer();
                this.isDeploying = false;

                if (status.success) {
                    this.deploySuccess = true;
                    this.deployStatus = this.label.success;
                    this.dispatchEvent(new CustomEvent('finish', {
                        detail: {
                            success: true,
                            message: this.label.success
                        }
                    }));
                } else {
                    this.deployError = status.errorMessage || this.label.failed;
                    this.deployStatus = this.label.failed;
                }
            } else {
                this.deployStatus = `${this.label.deploying} (${status.status || 'In Progress'})`;
            }
        } catch (error) {
            // Don't stop polling on transient errors
            if (this.pollAttempts > 5) {
                this.clearPollTimer();
                this.isDeploying = false;
                this.deployError = error.body?.message || LABEL_DEPLOY_CONN_LOST;
            }
        }
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    fireStepData() {
        this.dispatchEvent(new CustomEvent('stepdata', {
            detail: {
                sampleRecordId: this.sampleRecordId,
                isValid: true
            }
        }));
    }

    // ─── Computed ───────────────────────────────────────────────────────

    get hasSimulateResult() {
        return this.simulateResult !== null;
    }

    get simulateSuccess() {
        return this.simulateResult?.success === true;
    }

    get hasSimulateError() {
        return !!this.simulateError;
    }

    get hasDeployError() {
        return !!this.deployError;
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

    get resultErrorMessage() {
        return this.simulateResult?.errorMessage || '';
    }

    get isActivateDisabled() {
        return this.isDeploying || this.deploySuccess;
    }

    get showDeployStatus() {
        return this.isDeploying || this.deploySuccess || this.hasDeployError;
    }

    get configSummary() {
        const s = this.wizardState;
        if (!s) return '';
        return `${s.configLabel || ''} (${s.objectApiName || ''})`;
    }

    get conditionCount() {
        return this.wizardState?.conditions?.length || 0;
    }

    get agentCount() {
        return this.wizardState?.agents?.length || 0;
    }
}
