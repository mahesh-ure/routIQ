/**
 * @description Layer 5 -- Agent Work Panel LWC. Primary agent-facing component
 *              for the pull-model routing workflow:
 *
 *              Get Work -> View SLA Countdown -> Defer (or complete)
 *
 *              Features:
 *              - Availability toggle (Online/Busy/Away/Offline)
 *              - Next Best Action button (delegates to RoutingService)
 *              - SLA countdown timer (JS-only, zero server calls per tick)
 *              - Defer button (resets configured field, publishes DEFERRED event)
 *              - Queue depth indicator (wired, reactive on configDevName)
 *              - Current load / capacity display
 *              - 10s auto-refresh tick that runs the WorkItemReaper server-side
 *                so Current Load drops as soon as the agent closes a record
 *
 *              Server interactions (split by purpose, NOT consolidated):
 *
 *              READS (cacheable, @wire-bound, LDS-cached):
 *                - getAgentContext  → wiredAgent  (initial agent state)
 *                - getQueueDepth    → wiredQueue  (reactive on $configDevName,
 *                                                  falls back to all-active
 *                                                  configs when blank)
 *
 *              READ + SELF-HEAL (non-cacheable, runs DML via reaper):
 *                - refreshAgentContext  (10s tick — reaps zombie work items
 *                                        then returns fresh AgentContext)
 *
 *              MUTATIONS (non-cacheable, imperative):
 *                - getNextWork          (route + assign + publish PE)
 *                - deferWork            (reset field + delete work item + PE)
 *                - updateAgentStatus    (availability toggle)
 *
 *              The split exists because Salesforce forbids DML inside
 *              cacheable=true methods, and @wire only accepts cacheable
 *              methods. So mutations + reaper-driven refresh stay imperative.
 *
 *              Design:
 *              - All text via Custom Labels (i18n)
 *              - No lwc:dom="manual", no innerHTML (XSS-safe)
 *              - configDevName is @api so admins can bind the panel to a
 *                specific config from App Builder; blank works out-of-box
 *              - connectedCallback / disconnectedCallback for timer lifecycle
 *
 * @group UI
 */
import { LightningElement, api, track, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getObjectInfo } from 'lightning/uiObjectInfoApi';
import { IsConsoleNavigation, openTab } from 'lightning/platformWorkspaceApi';
import { refreshApex } from '@salesforce/apex';

// ── Apex Methods ────────────────────────────────────────────────────────────
import getAgentContext from '@salesforce/apex/AgentWorkPanelController.getAgentContext';
import refreshAgentContext from '@salesforce/apex/AgentWorkPanelController.refreshAgentContext';
import getNextWork from '@salesforce/apex/AgentWorkPanelController.getNextWork';
import deferWork from '@salesforce/apex/AgentWorkPanelController.deferWork';
import getQueueDepth from '@salesforce/apex/AgentWorkPanelController.getQueueDepth';
import updateAgentStatus from '@salesforce/apex/AgentAvailabilityController.updateAgentStatus';

// ── Custom Labels (i18n) ────────────────────────────────────────────────────
import LABEL_TITLE from '@salesforce/label/c.URE_WorkPanelTitle';
import LABEL_QUEUE_DEPTH from '@salesforce/label/c.URE_WorkPanelQueueDepth';
import LABEL_CURRENT_LOAD from '@salesforce/label/c.URE_WorkPanelCurrentLoad';
import LABEL_NEXT_BEST_ACTION from '@salesforce/label/c.URE_NextBestAction';
import LABEL_ROUTING from '@salesforce/label/c.URE_Routing';
import LABEL_DEFER from '@salesforce/label/c.URE_WorkPanelDefer';
import LABEL_DEFERRING from '@salesforce/label/c.URE_WorkPanelDeferring';
import LABEL_ONLINE from '@salesforce/label/c.URE_WorkPanelOnline';
import LABEL_BUSY from '@salesforce/label/c.URE_WorkPanelBusy';
import LABEL_AWAY from '@salesforce/label/c.URE_WorkPanelAway';
import LABEL_OFFLINE from '@salesforce/label/c.URE_WorkPanelOffline';
import LABEL_STATUS from '@salesforce/label/c.URE_WorkPanelStatusLabel';
import LABEL_SLA_REMAINING from '@salesforce/label/c.URE_WorkPanelSlaRemaining';
import LABEL_SLA_EXPIRED from '@salesforce/label/c.URE_WorkPanelSlaExpired';
import LABEL_EMPTY_TITLE from '@salesforce/label/c.URE_WorkPanelEmptyTitle';
import LABEL_EMPTY_BODY from '@salesforce/label/c.URE_WorkPanelEmptyBody';
import LABEL_DEFER_SUCCESS from '@salesforce/label/c.URE_WorkPanelDeferSuccess';
import LABEL_DEFER_ERROR from '@salesforce/label/c.URE_WorkPanelDeferError';
import LABEL_ROUTING_ERROR from '@salesforce/label/c.URE_RoutingError';
import LABEL_RECORD_ASSIGNED from '@salesforce/label/c.URE_RecordAssigned';
import LABEL_ASSIGNMENT_SUCCESS_TITLE from '@salesforce/label/c.URE_AssignmentSuccessTitle';
import LABEL_ASSIGNMENT_SUCCESS_MESSAGE from '@salesforce/label/c.URE_AssignmentSuccessMessage';
import LABEL_NO_RECORDS from '@salesforce/label/c.URE_NoRecordsAvailable';
import LABEL_UNEXPECTED_ERROR from '@salesforce/label/c.URE_UnexpectedError';
import LABEL_LOADING_WORK from '@salesforce/label/c.URE_WorkPanelLoadingWork';
import LABEL_ASSIGNED from '@salesforce/label/c.URE_Assigned';

// ── Constants ──────────────────────────────────────────────────────────────
// Auto-refresh interval for agent context + queue depth (client-side only).
// Picked at 10s to keep the load/capacity counters in sync with reaper /
// other agents' actions without flooding Apex.
const AUTO_REFRESH_MS = 10000;

export default class UreAgentWorkPanel extends NavigationMixin(LightningElement) {

    // ─── Labels exposed to template ─────────────────────────────────────
    label = {
        title: LABEL_TITLE,
        queueDepth: LABEL_QUEUE_DEPTH,
        currentLoad: LABEL_CURRENT_LOAD,
        nextBestAction: LABEL_NEXT_BEST_ACTION,
        routing: LABEL_ROUTING,
        defer: LABEL_DEFER,
        deferring: LABEL_DEFERRING,
        online: LABEL_ONLINE,
        busy: LABEL_BUSY,
        away: LABEL_AWAY,
        offline: LABEL_OFFLINE,
        statusLabel: LABEL_STATUS,
        slaRemaining: LABEL_SLA_REMAINING,
        slaExpired: LABEL_SLA_EXPIRED,
        emptyTitle: LABEL_EMPTY_TITLE,
        emptyBody: LABEL_EMPTY_BODY,
        deferSuccess: LABEL_DEFER_SUCCESS,
        deferError: LABEL_DEFER_ERROR,
        routingError: LABEL_ROUTING_ERROR,
        recordAssigned: LABEL_RECORD_ASSIGNED,
        assignmentSuccessTitle: LABEL_ASSIGNMENT_SUCCESS_TITLE,
        assignmentSuccessMessage: LABEL_ASSIGNMENT_SUCCESS_MESSAGE,
        noRecords: LABEL_NO_RECORDS,
        unexpectedError: LABEL_UNEXPECTED_ERROR,
        loadingWork: LABEL_LOADING_WORK,
        assigned: LABEL_ASSIGNED
    };

    // ─── Design attributes (set from App Builder) ───────────────────────
    /**
     * Developer name of a specific Routing_Config__mdt to lock the panel to.
     * Set by the admin from App Builder via the targetConfig in meta.xml.
     *
     * - Provided  → Get Next Work routes only against this config and the
     *               Queue widget shows the count of pending candidates for
     *               this config alone.
     * - Blank/null → Get Next Work routes across all active configs and the
     *               Queue widget shows the SUM of pending candidates across
     *               every active routing config (server-side fallback in
     *               AgentWorkPanelController.getQueueDepth).
     *
     * Reactive: changing this value re-fires both the @wire(getQueueDepth)
     * binding and any future config-aware @wires automatically.
     */
    @api configDevName = null;

    // ─── Agent context state ────────────────────────────────────────────
    @track agentContext = null;
    agentError = false;
    _wiredAgentResult;

    // ─── Work assignment state ──────────────────────────────────────────
    @track currentWork = null;
    recordUrl = null;
    isRouting = false;
    isDeferring = false;

    // ─── Assignment success banner: reactive object-label resolution ────
    /** @type {string|null} Reactive SObject API name driving getObjectInfo */
    @track assignedObjectApiName = null;
    /** @type {string|null} Translated object label (e.g. "Case") */
    assignedObjectLabel = null;

    @wire(getObjectInfo, { objectApiName: '$assignedObjectApiName' })
    wiredAssignedObjectInfo({ data }) {
        if (data && data.label) {
            this.assignedObjectLabel = data.label;
        }
    }

    /** @type {boolean} True when hosted in a Console app — enables openTab */
    @wire(IsConsoleNavigation) isConsoleNavigation;

    // ─── Queue depth ────────────────────────────────────────────────────
    // Populated by the @wire(getQueueDepth) binding below — never set
    // imperatively. Use refreshApex(this._wiredQueueResult) to force a
    // re-fetch (e.g. after a routing assignment or defer mutation drains
    // the queue, or on every auto-refresh tick to keep the number honest).
    @track queueCount = null;
    _wiredQueueResult;

    // ─── SLA countdown ──────────────────────────────────────────────────
    _slaTimerId = null;
    @track slaDisplay = '';
    @track slaPercent = 100;
    @track slaExpired = false;
    _slaDeadlineMs = null;
    _slaStartMs = null;

    // ─── Auto-refresh (client-side only) ────────────────────────────────
    // Re-pulls agent context (currentLoad / maxCapacity / status) and
    // queue depth on a fixed interval. No router calls — purely
    // informational so the panel stays in sync with reaper / other agents.
    _autoRefreshTimerId = null;
    _visibilityHandler = null;

    // =========================================================================
    // WIRED DATA
    // =========================================================================

    /**
     * Wired loader for the running user's Agent__c context (status, current
     * load, max capacity, last assigned). cacheable=true on the Apex side, so
     * Lightning Data Service caches the result across components and tabs.
     *
     * Refreshed by:
     *   - refreshApex(this._wiredAgentResult) after a defer/route mutation
     *   - The 10-second auto-refresh tick (which delegates to the
     *     non-cacheable refreshAgentContext() so the WorkItemReaper can
     *     also drop drift before returning the new context)
     */
    @wire(getAgentContext)
    wiredAgent(result) {
        this._wiredAgentResult = result;
        const { data, error } = result;
        if (data) {
            this.agentContext = data;
            this.agentError = false;
        } else if (error) {
            this.agentContext = null;
            this.agentError = true;
        }
    }

    /**
     * Wired Queue Depth for the panel's "Queue" metric. Reactive on
     * $configDevName so the count refreshes the moment the admin re-binds
     * the panel to a different routing config in App Builder.
     *
     * Behaviour driven by AgentWorkPanelController.getQueueDepth:
     *   - configDevName provided → COUNT() of pending candidates for THAT
     *     config only.
     *   - configDevName blank    → SUM of COUNT() across every active
     *     routing config (server-side fallback so the widget works on a
     *     fresh install before the admin has chosen a config).
     *
     * cacheable=true on the Apex side → LDS cache shared across components
     * (e.g. utility bar panel + record-page panel see the same number with
     * a single SOQL hit). Manual refreshes via refreshApex(_wiredQueueResult)
     * happen on:
     *   - successful Get Next Work (queue drained by 1)
     *   - successful Defer        (record returns to queue)
     *   - the 10-second auto-refresh tick (catches drains/inserts caused
     *     by other agents and inbound integration traffic)
     */
    @wire(getQueueDepth, { configDevName: '$configDevName' })
    wiredQueue(result) {
        this._wiredQueueResult = result;
        const { data, error } = result;
        if (data !== undefined && data !== null) {
            this.queueCount = data;
        } else if (error) {
            this.queueCount = null;
        }
    }

    // =========================================================================
    // LIFECYCLE
    // =========================================================================

    connectedCallback() {
        this._startAutoRefresh();
    }

    disconnectedCallback() {
        this._clearSlaTimer();
        this._stopAutoRefresh();
    }

    // =========================================================================
    // COMPUTED PROPERTIES
    // =========================================================================

    get hasAgent() {
        return this.agentContext != null;
    }

    get hasWork() {
        return this.currentWork != null;
    }

    get displayName() {
        if (!this.currentWork) return '';
        return this.currentWork.recordName || this.currentWork.recordId || '';
    }

    get agentStatus() {
        return this.agentContext?.status || 'Offline';
    }

    get isAvailable() {
        const status = this.agentStatus;
        return status === 'Online' || status === 'Busy';
    }

    get nextButtonLabel() {
        return this.isRouting ? this.label.routing : this.label.nextBestAction;
    }

    get isNextDisabled() {
        return this.isRouting || !this.isAvailable;
    }

    get deferButtonLabel() {
        return this.isDeferring ? this.label.deferring : this.label.defer;
    }

    get isDeferDisabled() {
        return this.isDeferring || !this.hasWork;
    }

    get loadDisplay() {
        if (!this.agentContext) return '0 / 0';
        return `${this.agentContext.currentLoad || 0} / ${this.agentContext.maxCapacity || 0}`;
    }

    /**
     * Display value for the Queue metric in the panel header. Returns the
     * raw count once the @wire(getQueueDepth) binding has resolved, or
     * "--" while the wire is still in flight or has errored. The wire
     * resolves with `null`/0 only on a clean empty result, so "--"
     * specifically signals "not yet known", not "zero".
     */
    get queueDisplay() {
        return this.queueCount != null ? this.queueCount : '--';
    }

    get hasSla() {
        return this._slaDeadlineMs != null;
    }

    get slaColorClass() {
        if (this.slaExpired) return 'sla-red';
        if (this.slaPercent <= 20) return 'sla-red';
        if (this.slaPercent <= 50) return 'sla-amber';
        return 'sla-green';
    }

    get slaText() {
        if (this.slaExpired) return this.label.slaExpired;
        return this.slaDisplay;
    }

    // ── Status button variants ──────────────────────────────────────────

    get statusOptions() {
        return [
            { label: this.label.online, value: 'Online' },
            { label: this.label.busy, value: 'Busy' },
            { label: this.label.away, value: 'Away' },
            { label: this.label.offline, value: 'Offline' }
        ];
    }

    get statusBadgeClass() {
        const status = this.agentStatus.toLowerCase();
        return `status-badge status-${status}`;
    }

    // =========================================================================
    // EVENT HANDLERS
    // =========================================================================

    /**
     * @description Handles availability status change from the combobox.
     */
    async handleStatusChange(event) {
        const newStatus = event.detail.value;
        if (newStatus === this.agentStatus) return;

        try {
            await updateAgentStatus({
                agentId: this.agentContext.agentId,
                status: newStatus
            });
            await refreshApex(this._wiredAgentResult);
        } catch (error) {
            this.dispatchEvent(new ShowToastEvent({
                title: this.label.routingError,
                message: error.body?.message || this.label.unexpectedError,
                variant: 'error'
            }));
        }
    }

    /**
     * @description "Next Best Action" -- pull next work item.
     */
    async handleGetNextWork() {
        this.isRouting = true;
        this.recordUrl = null;

        try {
            const result = await getNextWork({
                configDevName: this.configDevName
            });

            if (result.success) {
                this.currentWork = result;
                this._generateRecordUrl(result.recordId);
                this._startSlaCountdown(result.slaDeadline);

                // Trigger getObjectInfo to resolve the translated object label
                this.assignedObjectApiName = result.objectApiName || null;

                this._fireAssignmentSuccessBanner(result);
                this._openAssignedRecord(result.recordId);

                // Refresh agent context (load changed) and queue depth.
                // refreshApex on both wires invalidates the LDS cache and
                // re-fetches from the server so the metrics reflect the
                // post-routing state immediately.
                await refreshApex(this._wiredAgentResult);
                if (this._wiredQueueResult) {
                    refreshApex(this._wiredQueueResult);
                }
            } else {
                this.currentWork = null;
                this._clearSlaTimer();
                this.dispatchEvent(new ShowToastEvent({
                    title: this.label.routingError,
                    message: result.errorMessage || this.label.noRecords,
                    variant: 'warning'
                }));
            }
        } catch (error) {
            this.currentWork = null;
            this._clearSlaTimer();
            this.dispatchEvent(new ShowToastEvent({
                title: this.label.routingError,
                message: error.body?.message || this.label.unexpectedError,
                variant: 'error'
            }));
        } finally {
            this.isRouting = false;
        }
    }

    /**
     * @description Defer the currently assigned work item.
     */
    async handleDefer() {
        if (!this.currentWork) return;

        this.isDeferring = true;

        try {
            await deferWork({
                recordId: this.currentWork.recordId,
                configDevName: this.currentWork.configDevName || this.configDevName
            });

            this.currentWork = null;
            this.recordUrl = null;
            this._clearSlaTimer();

            this.dispatchEvent(new ShowToastEvent({
                title: this.label.deferSuccess,
                message: '',
                variant: 'success'
            }));

            // Refresh agent context (load changed) and queue depth.
            // The deferred record returns to the candidate pool so the
            // queue count should bump up by 1 on the re-fetch.
            await refreshApex(this._wiredAgentResult);
            if (this._wiredQueueResult) {
                refreshApex(this._wiredQueueResult);
            }
        } catch (error) {
            this.dispatchEvent(new ShowToastEvent({
                title: this.label.deferError,
                message: error.body?.message || this.label.unexpectedError,
                variant: 'error'
            }));
        } finally {
            this.isDeferring = false;
        }
    }

    /**
     * @description Navigate to the assigned record.
     */
    handleNavigate(event) {
        event.preventDefault();
        if (this.currentWork?.recordId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: this.currentWork.recordId,
                    actionName: 'view'
                }
            });
        }
    }

    // =========================================================================
    // PRIVATE HELPERS
    // =========================================================================

    /**
     * @description Builds and dispatches the "Assignment Successful" sticky
     *              banner. Fires in BOTH Console and Standard apps — the only
     *              branch is which navigation API we use afterwards. Sticky
     *              mode forces the agent to acknowledge, preventing missed
     *              assignments during high-volume routing.
     */
    _fireAssignmentSuccessBanner(result) {
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
     * @description Opens the assigned record for the agent. Runtime-aware:
     *              in a Console app it opens a focused workspace subtab via
     *              platformWorkspaceApi.openTab; in a Standard Lightning app
     *              it navigates via NavigationMixin. Either path, the sticky
     *              banner has already fired so the agent is always informed.
     */
    async _openAssignedRecord(recordId) {
        if (!recordId) return;
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
     * @description Generates a Lightning URL for the record link.
     */
    _generateRecordUrl(recordId) {
        if (!recordId) return;
        this[NavigationMixin.GenerateUrl]({
            type: 'standard__recordPage',
            attributes: {
                recordId: recordId,
                actionName: 'view'
            }
        }).then((url) => {
            this.recordUrl = url;
        });
    }

    /**
     * @description Starts the SLA countdown timer. Runs every second,
     *              zero server calls per tick. Stores the deadline and
     *              start timestamps for percentage calculation.
     */
    _startSlaCountdown(slaDeadline) {
        this._clearSlaTimer();

        if (!slaDeadline) {
            this._slaDeadlineMs = null;
            this.slaDisplay = '';
            this.slaPercent = 100;
            this.slaExpired = false;
            return;
        }

        this._slaDeadlineMs = new Date(slaDeadline).getTime();
        this._slaStartMs = Date.now();

        this._tickSla();
        this._slaTimerId = setInterval(() => this._tickSla(), 1000);
    }

    /**
     * @description Single tick of the SLA countdown. Calculates remaining
     *              time, formats display string, computes percentage for
     *              colour thresholds.
     */
    _tickSla() {
        const now = Date.now();
        const remaining = this._slaDeadlineMs - now;
        const total = this._slaDeadlineMs - this._slaStartMs;

        if (remaining <= 0) {
            this.slaDisplay = '00:00:00';
            this.slaPercent = 0;
            this.slaExpired = true;
            this._clearSlaTimer();
            return;
        }

        this.slaExpired = false;
        this.slaPercent = total > 0 ? Math.round((remaining / total) * 100) : 100;

        const hours = Math.floor(remaining / 3600000);
        const minutes = Math.floor((remaining % 3600000) / 60000);
        const seconds = Math.floor((remaining % 60000) / 1000);

        this.slaDisplay =
            String(hours).padStart(2, '0') + ':' +
            String(minutes).padStart(2, '0') + ':' +
            String(seconds).padStart(2, '0');
    }

    /**
     * @description Clears the SLA interval timer.
     */
    _clearSlaTimer() {
        if (this._slaTimerId) {
            clearInterval(this._slaTimerId);
            this._slaTimerId = null;
        }
    }

    /**
     * @description Starts the client-side auto-refresh loop. Re-pulls
     *              agent context and queue depth every AUTO_REFRESH_MS.
     *              Pauses while the tab is hidden (Page Visibility API)
     *              to avoid wasted server traffic when the agent is
     *              looking elsewhere.
     */
    _startAutoRefresh() {
        // Defensive: never double-start
        this._stopAutoRefresh();

        this._autoRefreshTimerId = setInterval(
            () => this._tickAutoRefresh(),
            AUTO_REFRESH_MS
        );

        // Pause/resume on tab visibility change
        if (typeof document !== 'undefined' && document.addEventListener) {
            this._visibilityHandler = () => {
                if (document.hidden) {
                    if (this._autoRefreshTimerId) {
                        clearInterval(this._autoRefreshTimerId);
                        this._autoRefreshTimerId = null;
                    }
                } else if (!this._autoRefreshTimerId) {
                    // Immediate refresh on resume so the agent sees fresh
                    // numbers the moment they return to the tab
                    this._tickAutoRefresh();
                    this._autoRefreshTimerId = setInterval(
                        () => this._tickAutoRefresh(),
                        AUTO_REFRESH_MS
                    );
                }
            };
            document.addEventListener('visibilitychange', this._visibilityHandler);
        }
    }

    /**
     * @description Stops the auto-refresh loop and removes the
     *              visibility listener. Idempotent.
     */
    _stopAutoRefresh() {
        if (this._autoRefreshTimerId) {
            clearInterval(this._autoRefreshTimerId);
            this._autoRefreshTimerId = null;
        }
        if (this._visibilityHandler && typeof document !== 'undefined') {
            document.removeEventListener('visibilitychange', this._visibilityHandler);
            this._visibilityHandler = null;
        }
    }

    /**
     * One pulse of the 10-second auto-refresh loop. Keeps the panel's
     * Current Load + Queue widgets honest without forcing the agent to
     * reload the page. Skips work when:
     *
     *   - No agent context has loaded yet (first wire still in flight).
     *   - A user-initiated route/defer is mid-flight (don't clobber the
     *     optimistic UI mid-mutation — the mutation handler runs its own
     *     refreshApex on completion).
     *
     * Two server interactions per tick:
     *
     *   1. refreshAgentContext (non-cacheable, AuraEnabled): runs the
     *      WorkItemReaper for the running user server-side, completes any
     *      Agent_Work_Item__c rows whose source record was closed/deleted
     *      since the last tick, then returns the freshly-loaded
     *      AgentContext. This is what makes the Current Load gauge drop
     *      the moment the agent closes an assigned Case/Opp. The
     *      response replaces this.agentContext directly — no refreshApex
     *      needed because the payload shape matches the wired result.
     *
     *   2. refreshApex(_wiredQueueResult): re-runs getQueueDepth via the
     *      LDS cache layer so the Queue metric reflects new candidates
     *      arriving from inbound integrations or other agents pulling
     *      work from the same pool.
     *
     * All errors are swallowed silently — this is a background refresh,
     * not a user action, and a transient failure must not toast the
     * agent or break the cadence.
     */
    _tickAutoRefresh() {
        if (!this._wiredAgentResult || this.isRouting || this.isDeferring) {
            return;
        }
        refreshAgentContext()
            .then((ctx) => {
                if (ctx) {
                    this.agentContext = ctx;
                }
            })
            .catch(() => {
                // Silent — informational refresh, do not toast
            });
        if (this._wiredQueueResult) {
            refreshApex(this._wiredQueueResult).catch(() => {
                // Silent — informational refresh, do not toast
            });
        }
    }
}
