/**
 * @description Agent-facing routing console for the Utility Bar. Provides a
 *              human-initiated "Next Best Action" button that calls the routIQ
 *              routing engine and displays the last assigned record name as a
 *              clickable link.
 *
 *              Design constraints:
 *              • NEVER fires on load — routing only on explicit button click.
 *              • Imperative Apex call (not @wire) — this is a mutation, not a read.
 *              • Persists last result across page navigation (utility bar lifecycle).
 *              • All business logic lives server-side in RoutingService → RoutingEngine.
 *              • All user-facing text via Custom Labels (i18n / multi-language).
 *              • No lwc:dom="manual", no innerHTML — XSS safe (AppExchange compliant).
 *
 * @group UI
 */
import { LightningElement } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getNextRecord from '@salesforce/apex/RoutingService.getNextRecord';

// ── Custom Labels (i18n) ─────────────────────────────────────────────────────
import LABEL_NEXT_BEST_ACTION from '@salesforce/label/c.URE_NextBestAction';
import LABEL_ROUTING from '@salesforce/label/c.URE_Routing';
import LABEL_ASSIGNED from '@salesforce/label/c.URE_Assigned';
import LABEL_RECORD_ASSIGNED from '@salesforce/label/c.URE_RecordAssigned';
import LABEL_ROUTING_ERROR from '@salesforce/label/c.URE_RoutingError';
import LABEL_NO_RECORDS from '@salesforce/label/c.URE_NoRecordsAvailable';
import LABEL_UNEXPECTED_ERROR from '@salesforce/label/c.URE_UnexpectedError';
import LABEL_FINDING_NEXT from '@salesforce/label/c.URE_FindingNextRecord';

export default class RoutingConsole extends NavigationMixin(LightningElement) {

    // ─── Labels exposed to template ─────────────────────────────────────
    label = {
        nextBestAction: LABEL_NEXT_BEST_ACTION,
        routing: LABEL_ROUTING,
        assigned: LABEL_ASSIGNED,
        recordAssigned: LABEL_RECORD_ASSIGNED,
        routingError: LABEL_ROUTING_ERROR,
        noRecords: LABEL_NO_RECORDS,
        unexpectedError: LABEL_UNEXPECTED_ERROR,
        findingNext: LABEL_FINDING_NEXT
    };

    /** @type {boolean} True while the Apex call is in flight */
    isLoading = false;

    /** @type {Object|null} Last RoutingResult from the server */
    lastResult = null;

    /** @type {string|null} Generated Lightning URL for the assigned record */
    recordUrl = null;

    // ─── Computed Properties ────────────────────────────────────────────

    get hasResult() {
        return this.lastResult !== null;
    }

    get isSuccess() {
        return this.lastResult?.success === true;
    }

    get isFailure() {
        return this.hasResult && !this.isSuccess;
    }

    /** Falls back to recordId when recordName is unavailable */
    get displayName() {
        if (!this.lastResult) {
            return '';
        }
        return this.lastResult.recordName || this.lastResult.recordId || '';
    }

    get errorMessage() {
        if (!this.lastResult) {
            return '';
        }
        return this.lastResult.errorMessage || this.label.noRecords;
    }

    get buttonLabel() {
        return this.isLoading ? this.label.routing : this.label.nextBestAction;
    }

    // ─── Event Handlers ─────────────────────────────────────────────────

    /**
     * @description Imperative call to RoutingService.getNextRecord().
     *              All params null = "Next Best Action" across all active configs —
     *              the engine evaluates which config matches this agent's
     *              skills/attributes and pulls the best candidate.
     */
    async handleGetNext() {
        this.isLoading = true;
        this.recordUrl = null;

        try {
            const result = await getNextRecord({
                objectApiName: null,
                recordId: null,
                configDeveloperName: null,
                dryRun: false
            });

            this.lastResult = result;

            if (result.success) {
                // Generate Lightning URL for the assigned record
                this[NavigationMixin.GenerateUrl]({
                    type: 'standard__recordPage',
                    attributes: {
                        recordId: result.recordId,
                        actionName: 'view'
                    }
                }).then((url) => {
                    this.recordUrl = url;
                });

                this.dispatchEvent(new ShowToastEvent({
                    title: this.label.recordAssigned,
                    message: result.recordName || result.recordId,
                    variant: 'success'
                }));
            }
        } catch (error) {
            // Network-level or unhandled Apex exception
            this.lastResult = {
                success: false,
                errorMessage: error.body?.message || this.label.unexpectedError
            };
            this.dispatchEvent(new ShowToastEvent({
                title: this.label.routingError,
                message: this.lastResult.errorMessage,
                variant: 'error'
            }));
        } finally {
            this.isLoading = false;
        }
    }

    /**
     * @description Navigates to the assigned record using NavigationMixin.
     *              Prevents default anchor behavior so Lightning handles
     *              the navigation within the SPA shell.
     */
    handleNavigate(event) {
        event.preventDefault();
        if (this.lastResult?.recordId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: this.lastResult.recordId,
                    actionName: 'view'
                }
            });
        }
    }
}
