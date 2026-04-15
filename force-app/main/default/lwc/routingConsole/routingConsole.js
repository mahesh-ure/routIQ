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
import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getObjectInfo } from 'lightning/uiObjectInfoApi';
import { IsConsoleNavigation, openTab } from 'lightning/platformWorkspaceApi';
import getNextRecord from '@salesforce/apex/RoutingService.getNextRecord';

// ── Custom Labels (i18n) ─────────────────────────────────────────────────────
import LABEL_NEXT_BEST_ACTION from '@salesforce/label/c.URE_NextBestAction';
import LABEL_ROUTING from '@salesforce/label/c.URE_Routing';
import LABEL_ASSIGNED from '@salesforce/label/c.URE_Assigned';
import LABEL_RECORD_ASSIGNED from '@salesforce/label/c.URE_RecordAssigned';
import LABEL_ASSIGNMENT_SUCCESS_TITLE from '@salesforce/label/c.URE_AssignmentSuccessTitle';
import LABEL_ASSIGNMENT_SUCCESS_MESSAGE from '@salesforce/label/c.URE_AssignmentSuccessMessage';
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
        assignmentSuccessTitle: LABEL_ASSIGNMENT_SUCCESS_TITLE,
        assignmentSuccessMessage: LABEL_ASSIGNMENT_SUCCESS_MESSAGE,
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

    /** @type {string|null} Reactive object API name used by getObjectInfo wire */
    assignedObjectApiName = null;

    /** @type {string|null} Display label for the assigned object (e.g. "Case") */
    assignedObjectLabel = null;

    /**
     * @description Resolves the user-facing label for the assigned SObject
     *              (respects translations / org renames). Falls back silently
     *              to the API name if metadata is unavailable.
     */
    @wire(getObjectInfo, { objectApiName: '$assignedObjectApiName' })
    wiredObjectInfo({ data }) {
        if (data && data.label) {
            this.assignedObjectLabel = data.label;
        }
    }

    /** @type {boolean} True when hosted inside a Console app (enables openTab) */
    @wire(IsConsoleNavigation) isConsoleNavigation;

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
                // Trigger getObjectInfo wire to resolve the translated object label
                this.assignedObjectApiName = result.objectApiName || null;

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

                this.fireAssignmentSuccessBanner(result);
                this.openAssignedRecord(result.recordId);
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
     * @description Builds and dispatches the "Assignment Successful" success
     *              banner. Uses the translated SObject label (from getObjectInfo)
     *              when available, falling back to the API name. Mode 'sticky'
     *              so the agent must acknowledge — prevents missed assignments
     *              during high-volume routing.
     */
    fireAssignmentSuccessBanner(result) {
        const objectDisplay = this.assignedObjectLabel
            || result.objectApiName
            || '';
        const recordDisplay = result.recordName || result.recordId || '';

        const message = this.label.assignmentSuccessMessage
            .replace('{0}', objectDisplay)
            .replace('{1}', recordDisplay)
            .trim();

        this.dispatchEvent(new ShowToastEvent({
            title: this.label.assignmentSuccessTitle,
            message: message,
            variant: 'success',
            mode: 'pester'
        }));
    }

    /**
     * @description Opens the assigned record. In a Console app this opens a
     *              focused workspace tab via platformWorkspaceApi.openTab. In a
     *              standard app (or if the workspace API rejects) it falls back
     *              to NavigationMixin.Navigate.
     */
    async openAssignedRecord(recordId) {
        if (!recordId) {
            return;
        }
        if (this.isConsoleNavigation) {
            try {
                await openTab({ recordId, focus: true });
                return;
            } catch (err) {
                // fall through to standard navigation
            }
        }
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: recordId,
                actionName: 'view'
            }
        });
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
