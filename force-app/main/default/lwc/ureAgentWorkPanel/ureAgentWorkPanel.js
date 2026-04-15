/**
 * @description Layer 5 -- Agent Work Panel LWC. Primary agent-facing component
 *              for the pull-model routing workflow:
 *
 *              Hydrate Assigned Work -> Next Best Action -> SLA Countdown -> Defer
 *
 *              Features:
 *              - Availability toggle (Online/Busy/Away/Offline)
 *              - Next Best Action button (delegates to RoutingService)
 *              - Multi-item work list (all active Agent_Work_Item__c rows)
 *              - Per-item SLA countdown with admin-tunable colour thresholds
 *                (Routing_Config__mdt.SLA_Warn_Threshold_Pct__c /
 *                SLA_Critical_Threshold_Pct__c — fallbacks 50/20)
 *              - Per-item Defer button
 *              - Queue depth indicator (wired, reactive on configDevName)
 *              - Current load / capacity display
 *              - 10s auto-refresh tick that runs the WorkItemReaper server-side
 *                so Current Load drops as soon as the agent closes a record
 *
 *              Server interactions (split by purpose):
 *
 *              READS (cacheable, @wire-bound, LDS-cached):
 *                - getAgentContext   → wiredAgent  (initial agent state)
 *                - getAssignedWork   → wiredAssigned (hydrate pre-existing
 *                                                     work items on load)
 *                - getQueueDepth     → wiredQueue  (reactive on $configDevName)
 *
 *              READ + SELF-HEAL (non-cacheable, runs DML via reaper):
 *                - refreshAgentContext  (10s tick)
 *
 *              MUTATIONS (non-cacheable, imperative):
 *                - getNextWork          (route + assign + publish PE)
 *                - deferWork            (reset field + delete work item + PE)
 *                - updateAgentStatus    (availability toggle)
 *
 *              Design:
 *              - All text via Custom Labels (i18n)
 *              - No lwc:dom="manual", no innerHTML (XSS-safe)
 *              - Thresholds come from server DTO — no hardcoded 50/20 in JS
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
import getAssignedWork from '@salesforce/apex/AgentWorkPanelController.getAssignedWork';
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
import LABEL_ASSIGNED_HEADER from '@salesforce/label/c.URE_WorkPanelAssignedHeader';
import LABEL_ITEM_COUNT from '@salesforce/label/c.URE_WorkPanelItemCount';

// ── Constants ──────────────────────────────────────────────────────────────
const AUTO_REFRESH_MS = 10000;
// Safety-net thresholds — apply ONLY when the server DTO omits a per-item
// value (which itself already falls back to Routing_Config__mdt fields +
// controller FALLBACK_* constants). Keep in sync with AgentWorkPanelController.
const FALLBACK_WARN_PCT = 50;
const FALLBACK_CRITICAL_PCT = 20;

export default class UreAgentWorkPanel extends NavigationMixin(LightningElement) {

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
        assigned: LABEL_ASSIGNED,
        assignedHeader: LABEL_ASSIGNED_HEADER,
        itemCount: LABEL_ITEM_COUNT
    };

    @api configDevName = null;

    // ─── Agent context state ────────────────────────────────────────────
    @track agentContext = null;
    agentError = false;
    _wiredAgentResult;

    // ─── Work list state ────────────────────────────────────────────────
    /**
     * Canonical list of active work items rendered in the panel.
     * Keyed by recordId for O(1) updates in the SLA tick loop.
     * Each entry shape matches the WorkAssignment Apex DTO plus the
     * precomputed display fields (url, sla text, colour class, expired).
     */
    @track workItems = [];
    _wiredAssignedResult;
    isRouting = false;
    /** Map<recordId, true> — which row is mid-defer (per-item spinner) */
    @track deferringIds = {};

    // ─── Reactive object-label resolution for toast messages ─────────────
    @track assignedObjectApiName = null;
    assignedObjectLabel = null;

    @wire(getObjectInfo, { objectApiName: '$assignedObjectApiName' })
    wiredAssignedObjectInfo({ data }) {
        if (data && data.label) {
            this.assignedObjectLabel = data.label;
        }
    }

    @wire(IsConsoleNavigation) isConsoleNavigation;

    // ─── Queue depth ────────────────────────────────────────────────────
    @track queueCount = null;
    _wiredQueueResult;

    // ─── SLA countdown — single interval drives ALL items ───────────────
    _slaTimerId = null;

    // ─── Auto-refresh (client-side only) ────────────────────────────────
    _autoRefreshTimerId = null;
    _visibilityHandler = null;

    // =========================================================================
    // WIRED DATA
    // =========================================================================

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
     * Hydrates the panel with every Active Agent_Work_Item__c for the running
     * agent on mount (and on refreshApex after route/defer). Server-side bulk
     * load includes per-item thresholds + SLA deadline, so the client never
     * computes colour off hardcoded numbers.
     */
    @wire(getAssignedWork)
    wiredAssigned(result) {
        this._wiredAssignedResult = result;
        const { data, error } = result;
        if (data) {
            this.workItems = data.map((row) => this._hydrateItem(row));
            this._ensureSlaTimer();
        } else if (error) {
            this.workItems = [];
        }
    }

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
        return this.workItems && this.workItems.length > 0;
    }

    get itemCountLabel() {
        return this.label.itemCount.replace('{0}', String(this.workItems.length));
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

    get loadDisplay() {
        if (!this.agentContext) return '0 / 0';
        return `${this.agentContext.currentLoad || 0} / ${this.agentContext.maxCapacity || 0}`;
    }

    get queueDisplay() {
        return this.queueCount != null ? this.queueCount : '--';
    }

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

    async handleGetNextWork() {
        this.isRouting = true;

        try {
            const result = await getNextWork({
                configDevName: this.configDevName
            });

            if (result.success) {
                this.assignedObjectApiName = result.objectApiName || null;
                this._fireAssignmentSuccessBanner(result);
                this._openAssignedRecord(result.recordId);

                // Server-side truth: re-fetch the assigned-work list so the
                // new record is included with full SLA + threshold payload.
                await Promise.all([
                    refreshApex(this._wiredAgentResult),
                    refreshApex(this._wiredAssignedResult),
                    this._wiredQueueResult ? refreshApex(this._wiredQueueResult) : Promise.resolve()
                ]);
            } else {
                this.dispatchEvent(new ShowToastEvent({
                    title: this.label.routingError,
                    message: result.errorMessage || this.label.noRecords,
                    variant: 'warning'
                }));
            }
        } catch (error) {
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
     * Per-row defer. event.currentTarget.dataset carries { recordId, configDevName }.
     */
    async handleDefer(event) {
        const { recordId, configDevName } = event.currentTarget.dataset;
        if (!recordId) return;

        this.deferringIds = { ...this.deferringIds, [recordId]: true };

        try {
            await deferWork({
                recordId,
                configDevName: configDevName || this.configDevName
            });

            this.dispatchEvent(new ShowToastEvent({
                title: this.label.deferSuccess,
                message: '',
                variant: 'success'
            }));

            await Promise.all([
                refreshApex(this._wiredAgentResult),
                refreshApex(this._wiredAssignedResult),
                this._wiredQueueResult ? refreshApex(this._wiredQueueResult) : Promise.resolve()
            ]);
        } catch (error) {
            this.dispatchEvent(new ShowToastEvent({
                title: this.label.deferError,
                message: error.body?.message || this.label.unexpectedError,
                variant: 'error'
            }));
        } finally {
            const next = { ...this.deferringIds };
            delete next[recordId];
            this.deferringIds = next;
        }
    }

    handleNavigate(event) {
        event.preventDefault();
        const recordId = event.currentTarget.dataset.recordId;
        if (recordId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId, actionName: 'view' }
            });
        }
    }

    // =========================================================================
    // PRIVATE HELPERS — WORK ITEM HYDRATION + SLA LOOP
    // =========================================================================

    /**
     * Turns a raw WorkAssignment DTO into the shape the template renders.
     * Precomputes:
     *   - recordUrl (NavigationMixin.GenerateUrl resolves async → populated later)
     *   - deadlineMs / assignedAtMs (numeric for tick math)
     *   - warnPct / criticalPct (server-driven, safety-net fallback here)
     *   - sla display fields (filled by _tickAllSla on the timer interval)
     *   - deferring flag (reactive on deferringIds map)
     */
    _hydrateItem(dto) {
        const warn = Number.isFinite(dto.slaWarnPct) ? dto.slaWarnPct : FALLBACK_WARN_PCT;
        const critical = Number.isFinite(dto.slaCriticalPct) ? dto.slaCriticalPct : FALLBACK_CRITICAL_PCT;
        // Guard against broken config data — invariant: warn > critical.
        const safeWarn = warn > critical ? warn : FALLBACK_WARN_PCT;
        const safeCritical = warn > critical ? critical : FALLBACK_CRITICAL_PCT;

        const deadlineMs = dto.slaDeadline ? new Date(dto.slaDeadline).getTime() : null;
        const assignedAtMs = dto.assignedAt ? new Date(dto.assignedAt).getTime() : Date.now();

        const item = {
            recordId: dto.recordId,
            recordName: dto.recordName || dto.recordId,
            objectApiName: dto.objectApiName,
            configDevName: dto.configDevName,
            assignedAt: dto.assignedAt,
            deadlineMs,
            assignedAtMs,
            warnPct: safeWarn,
            criticalPct: safeCritical,
            hasSla: deadlineMs != null,
            slaDisplay: '',
            slaPercent: 100,
            slaExpired: false,
            slaColorClass: 'sla-green',
            recordUrl: null
        };

        // Resolve navigation URL async — once resolved, patch via workItems clone
        this[NavigationMixin.GenerateUrl]({
            type: 'standard__recordPage',
            attributes: { recordId: dto.recordId, actionName: 'view' }
        }).then((url) => {
            this.workItems = this.workItems.map((w) =>
                w.recordId === dto.recordId ? { ...w, recordUrl: url } : w
            );
        });

        // Seed the SLA fields once so the first render is correct even
        // before the first interval fires.
        this._computeSla(item);
        return item;
    }

    /** Ensures exactly one SLA interval runs whenever at least one item has an SLA. */
    _ensureSlaTimer() {
        const anySla = this.workItems.some((w) => w.hasSla);
        if (!anySla) {
            this._clearSlaTimer();
            return;
        }
        if (this._slaTimerId) return;
        this._tickAllSla();
        this._slaTimerId = setInterval(() => this._tickAllSla(), 1000);
    }

    /** One pulse — updates sla fields on every item reactively. */
    _tickAllSla() {
        if (!this.workItems || this.workItems.length === 0) {
            this._clearSlaTimer();
            return;
        }
        this.workItems = this.workItems.map((item) => {
            if (!item.hasSla) return item;
            const next = { ...item };
            this._computeSla(next);
            return next;
        });
    }

    /** Mutates `item` in place with fresh slaDisplay/slaPercent/slaColorClass. */
    _computeSla(item) {
        if (!item.hasSla) {
            item.slaDisplay = '';
            item.slaPercent = 100;
            item.slaExpired = false;
            item.slaColorClass = 'sla-green';
            return;
        }
        const now = Date.now();
        const remaining = item.deadlineMs - now;
        const total = item.deadlineMs - item.assignedAtMs;

        if (remaining <= 0) {
            item.slaDisplay = '00:00:00';
            item.slaPercent = 0;
            item.slaExpired = true;
            item.slaColorClass = 'sla-red';
            return;
        }

        item.slaExpired = false;
        item.slaPercent = total > 0 ? Math.round((remaining / total) * 100) : 100;

        if (item.slaPercent <= item.criticalPct) {
            item.slaColorClass = 'sla-red';
        } else if (item.slaPercent <= item.warnPct) {
            item.slaColorClass = 'sla-amber';
        } else {
            item.slaColorClass = 'sla-green';
        }

        const hours = Math.floor(remaining / 3600000);
        const minutes = Math.floor((remaining % 3600000) / 60000);
        const seconds = Math.floor((remaining % 60000) / 1000);
        item.slaDisplay =
            String(hours).padStart(2, '0') + ':' +
            String(minutes).padStart(2, '0') + ':' +
            String(seconds).padStart(2, '0');
    }

    _clearSlaTimer() {
        if (this._slaTimerId) {
            clearInterval(this._slaTimerId);
            this._slaTimerId = null;
        }
    }

    // =========================================================================
    // PRIVATE HELPERS — BANNER + NAVIGATION
    // =========================================================================

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
            attributes: { recordId, actionName: 'view' }
        });
    }

    // =========================================================================
    // PRIVATE HELPERS — AUTO-REFRESH
    // =========================================================================

    _startAutoRefresh() {
        this._stopAutoRefresh();

        this._autoRefreshTimerId = setInterval(
            () => this._tickAutoRefresh(),
            AUTO_REFRESH_MS
        );

        if (typeof document !== 'undefined' && document.addEventListener) {
            this._visibilityHandler = () => {
                if (document.hidden) {
                    if (this._autoRefreshTimerId) {
                        clearInterval(this._autoRefreshTimerId);
                        this._autoRefreshTimerId = null;
                    }
                } else if (!this._autoRefreshTimerId) {
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
     * 10-second pulse — reaps zombie work items server-side, then refreshes
     * every wired dataset. Silent on failure. Skips while a user-initiated
     * route is in flight (mid-mutation noise).
     */
    _tickAutoRefresh() {
        if (!this._wiredAgentResult || this.isRouting) {
            return;
        }
        refreshAgentContext()
            .then((ctx) => {
                if (ctx) {
                    this.agentContext = ctx;
                }
            })
            .catch(() => { /* silent */ });
        if (this._wiredAssignedResult) {
            refreshApex(this._wiredAssignedResult).catch(() => { /* silent */ });
        }
        if (this._wiredQueueResult) {
            refreshApex(this._wiredQueueResult).catch(() => { /* silent */ });
        }
    }
}
