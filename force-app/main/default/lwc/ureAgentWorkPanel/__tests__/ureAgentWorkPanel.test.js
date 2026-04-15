import { createElement } from 'lwc';
import UreAgentWorkPanel from 'c/ureAgentWorkPanel';
import getAgentContext from '@salesforce/apex/AgentWorkPanelController.getAgentContext';
import getAssignedWork from '@salesforce/apex/AgentWorkPanelController.getAssignedWork';
import getNextWork from '@salesforce/apex/AgentWorkPanelController.getNextWork';
import deferWork from '@salesforce/apex/AgentWorkPanelController.deferWork';
import getQueueDepth from '@salesforce/apex/AgentWorkPanelController.getQueueDepth';
import updateAgentStatus from '@salesforce/apex/AgentAvailabilityController.updateAgentStatus';

// ── Mock Apex Methods ───────────────────────────────────────────────────────
jest.mock(
    '@salesforce/apex/AgentWorkPanelController.getAgentContext',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AgentWorkPanelController.getAssignedWork',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AgentWorkPanelController.refreshAgentContext',
    () => ({ default: jest.fn(() => Promise.resolve(null)) }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AgentWorkPanelController.getNextWork',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AgentWorkPanelController.deferWork',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AgentWorkPanelController.getQueueDepth',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AgentAvailabilityController.updateAgentStatus',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

// ── Mock Custom Labels ──────────────────────────────────────────────────────
jest.mock('@salesforce/label/c.URE_WorkPanelTitle', () => ({ default: 'My Work' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_WorkPanelQueueDepth', () => ({ default: 'In Queue' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_WorkPanelCurrentLoad', () => ({ default: 'My Load' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_NextBestAction', () => ({ default: 'Next Best Action' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_Routing', () => ({ default: 'Routing...' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_WorkPanelDefer', () => ({ default: 'Defer' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_WorkPanelDeferring', () => ({ default: 'Deferring...' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_WorkPanelOnline', () => ({ default: 'Online' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_WorkPanelBusy', () => ({ default: 'Busy' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_WorkPanelAway', () => ({ default: 'Away' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_WorkPanelOffline', () => ({ default: 'Offline' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_WorkPanelStatusLabel', () => ({ default: 'Availability' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_WorkPanelSlaRemaining', () => ({ default: 'SLA Remaining' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_WorkPanelSlaExpired', () => ({ default: 'SLA Expired' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_WorkPanelEmptyTitle', () => ({ default: 'No Work Assigned' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_WorkPanelEmptyBody', () => ({ default: 'Click Next Best Action to pull your next work item.' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_WorkPanelDeferSuccess', () => ({ default: 'Work Deferred' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_WorkPanelDeferError', () => ({ default: 'Defer Failed' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_RoutingError', () => ({ default: 'Routing Error' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_RecordAssigned', () => ({ default: 'Record Assigned' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_AssignmentSuccessTitle', () => ({ default: 'Assignment Successful' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_AssignmentSuccessMessage', () => ({ default: '{0} {1} has been successfully assigned to you.' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_NoRecordsAvailable', () => ({ default: 'No records available.' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_UnexpectedError', () => ({ default: 'An unexpected error occurred.' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_WorkPanelLoadingWork', () => ({ default: 'Finding next work item' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_Assigned', () => ({ default: 'Assigned' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_WorkPanelAssignedHeader', () => ({ default: 'Your Assigned Work' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_WorkPanelItemCount', () => ({ default: '{0} item(s)' }), { virtual: true });

// ── Test Data ───────────────────────────────────────────────────────────────
const MOCK_AGENT_CONTEXT = {
    agentId: 'a00000000000001AAA',
    status: 'Online',
    currentLoad: 2,
    maxCapacity: 10,
    isActive: true,
    lastAssigned: '2025-01-01T00:00:00.000Z'
};

/** Base WorkAssignment row shape — the server contract. */
function buildItem(overrides = {}) {
    const now = Date.now();
    return {
        success: true,
        recordId: '500000000000001AAA',
        recordName: 'Case-00001234',
        objectApiName: 'Case',
        configDevName: 'Test_Config',
        assignedAt: new Date(now - 5 * 60 * 1000).toISOString(), // assigned 5m ago
        slaDeadline: new Date(now + 55 * 60 * 1000).toISOString(), // 55m left → > 90% remaining
        slaWarnPct: 50,
        slaCriticalPct: 20,
        ...overrides
    };
}

const MOCK_WORK_SUCCESS = {
    success: true,
    recordId: '500000000000001AAA',
    recordName: 'Case-00001234',
    objectApiName: 'Case',
    assignedTo: '005000000000001AAA',
    routingLogId: 'a01000000000001AAA',
    errorMessage: null,
    slaDeadline: new Date(Date.now() + 3600000).toISOString(),
    assignedAt: new Date().toISOString(),
    slaWarnPct: 50,
    slaCriticalPct: 20,
    configDevName: 'Test_Config'
};

const MOCK_WORK_NO_MATCH = {
    success: false,
    recordId: null,
    recordName: null,
    objectApiName: null,
    assignedTo: null,
    routingLogId: null,
    errorMessage: 'No matching candidates found.',
    slaDeadline: null,
    configDevName: null
};

// ── Helpers ─────────────────────────────────────────────────────────────────

async function flushPromises() {
    return new Promise((resolve) => setTimeout(resolve, 0));
}

function createComponent() {
    const element = createElement('c-ure-agent-work-panel', { is: UreAgentWorkPanel });
    document.body.appendChild(element);
    return element;
}

function emitAgent(data) {
    getAgentContext.emit(data);
}

function emitAgentError() {
    getAgentContext.error();
}

function emitAssigned(items) {
    getAssignedWork.emit(items);
}

// ── Test Suite ──────────────────────────────────────────────────────────────

describe('c-ure-agent-work-panel', () => {

    beforeEach(() => {
        // Jest fake timers clash with async helper's setTimeout in some
        // scenarios — use real timers by default, opt in per test.
        jest.useRealTimers();
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    // ── Initial Render / Agent Context ──────────────────────────────────

    describe('initial render with agent context', () => {
        it('renders the card with title "My Work"', async () => {
            const element = createComponent();
            emitAgent(MOCK_AGENT_CONTEXT);
            emitAssigned([]);
            await flushPromises();

            const card = element.shadowRoot.querySelector('lightning-card');
            expect(card.title).toBe('My Work');
        });

        it('displays agent status badge', async () => {
            const element = createComponent();
            emitAgent(MOCK_AGENT_CONTEXT);
            emitAssigned([]);
            await flushPromises();

            const badge = element.shadowRoot.querySelector('.status-badge');
            expect(badge.textContent).toBe('Online');
        });

        it('displays current load as "2 / 10"', async () => {
            const element = createComponent();
            emitAgent(MOCK_AGENT_CONTEXT);
            emitAssigned([]);
            await flushPromises();

            const metrics = element.shadowRoot.querySelectorAll('.metric-value');
            expect(metrics[0].textContent).toBe('2 / 10');
        });

        it('renders empty state when assigned list is empty', async () => {
            const element = createComponent();
            emitAgent(MOCK_AGENT_CONTEXT);
            emitAssigned([]);
            await flushPromises();

            const emptyHeading = element.shadowRoot.querySelector('.empty-state .slds-text-heading_small');
            expect(emptyHeading.textContent).toBe('No Work Assigned');
        });

        it('enables Next Best Action when Online', async () => {
            const element = createComponent();
            emitAgent(MOCK_AGENT_CONTEXT);
            emitAssigned([]);
            await flushPromises();

            const nextBtn = Array.from(element.shadowRoot.querySelectorAll('lightning-button'))
                .find(b => b.label === 'Next Best Action');
            expect(nextBtn.disabled).toBe(false);
        });
    });

    // ── Pre-existing assigned work (the core gap this feature closes) ───

    describe('pre-existing assignments hydrated via @wire(getAssignedWork)', () => {
        it('renders the assigned header + item count', async () => {
            const element = createComponent();
            emitAgent(MOCK_AGENT_CONTEXT);
            emitAssigned([buildItem(), buildItem({ recordId: '500000000000002AAA', recordName: 'Case-00001235' })]);
            await flushPromises();

            const header = element.shadowRoot.querySelector('.slds-text-title_caps');
            expect(header.textContent).toBe('Your Assigned Work');

            const count = element.shadowRoot.querySelector('.slds-text-body_small.slds-text-color_weak');
            expect(count.textContent).toContain('2');
        });

        it('renders one work-card per assigned item', async () => {
            const element = createComponent();
            emitAgent(MOCK_AGENT_CONTEXT);
            emitAssigned([
                buildItem(),
                buildItem({ recordId: '500000000000002AAA', recordName: 'Case-00001235' }),
                buildItem({ recordId: '500000000000003AAA', recordName: 'Case-00001236' })
            ]);
            await flushPromises();

            const cards = element.shadowRoot.querySelectorAll('.work-card');
            expect(cards.length).toBe(3);
        });

        it('hides the empty state once items are emitted', async () => {
            const element = createComponent();
            emitAgent(MOCK_AGENT_CONTEXT);
            emitAssigned([buildItem()]);
            await flushPromises();

            expect(element.shadowRoot.querySelector('.empty-state')).toBeNull();
        });
    });

    // ── Agent Error State ───────────────────────────────────────────────

    describe('agent error state', () => {
        it('renders error illustration when no agent record exists', async () => {
            const element = createComponent();
            emitAgentError();
            await flushPromises();

            expect(element.shadowRoot.querySelector('lightning-illustration')).not.toBeNull();
        });

        it('does not render any lightning-button on agent error', async () => {
            const element = createComponent();
            emitAgentError();
            await flushPromises();

            expect(element.shadowRoot.querySelectorAll('lightning-button').length).toBe(0);
        });
    });

    // ── Availability Toggle ─────────────────────────────────────────────

    describe('availability toggle', () => {
        it('renders combobox with current status', async () => {
            const element = createComponent();
            emitAgent(MOCK_AGENT_CONTEXT);
            emitAssigned([]);
            await flushPromises();

            const combo = element.shadowRoot.querySelector('lightning-combobox');
            expect(combo.value).toBe('Online');
        });

        it('disables Next Best Action when status is Away', async () => {
            const element = createComponent();
            emitAgent({ ...MOCK_AGENT_CONTEXT, status: 'Away' });
            emitAssigned([]);
            await flushPromises();

            const nextBtn = Array.from(element.shadowRoot.querySelectorAll('lightning-button'))
                .find(b => b.label === 'Next Best Action');
            expect(nextBtn.disabled).toBe(true);
        });

        it('calls updateAgentStatus on combobox change', async () => {
            updateAgentStatus.mockResolvedValue('OK');
            const element = createComponent();
            emitAgent(MOCK_AGENT_CONTEXT);
            emitAssigned([]);
            await flushPromises();

            const combo = element.shadowRoot.querySelector('lightning-combobox');
            combo.dispatchEvent(new CustomEvent('change', { detail: { value: 'Busy' } }));
            await flushPromises();

            expect(updateAgentStatus).toHaveBeenCalledWith({
                agentId: 'a00000000000001AAA',
                status: 'Busy'
            });
        });
    });

    // ── Get Next Work ───────────────────────────────────────────────────

    describe('get next work', () => {
        it('fires success toast on successful assignment', async () => {
            getNextWork.mockResolvedValue(MOCK_WORK_SUCCESS);
            const element = createComponent();
            emitAgent(MOCK_AGENT_CONTEXT);
            emitAssigned([]);
            await flushPromises();

            const dispatchSpy = jest.spyOn(element, 'dispatchEvent');
            const nextBtn = Array.from(element.shadowRoot.querySelectorAll('lightning-button'))
                .find(b => b.label === 'Next Best Action');
            nextBtn.click();
            await flushPromises();

            const toastCalls = dispatchSpy.mock.calls.filter(
                (call) => call[0].type === 'lightning__showtoast'
            );
            expect(toastCalls[0][0].detail.variant).toBe('success');
        });

        it('shows warning toast on no-match', async () => {
            getNextWork.mockResolvedValue(MOCK_WORK_NO_MATCH);
            const element = createComponent();
            emitAgent(MOCK_AGENT_CONTEXT);
            emitAssigned([]);
            await flushPromises();

            const dispatchSpy = jest.spyOn(element, 'dispatchEvent');
            const nextBtn = Array.from(element.shadowRoot.querySelectorAll('lightning-button'))
                .find(b => b.label === 'Next Best Action');
            nextBtn.click();
            await flushPromises();

            const toastCalls = dispatchSpy.mock.calls.filter(
                (call) => call[0].type === 'lightning__showtoast'
            );
            expect(toastCalls[0][0].detail.variant).toBe('warning');
        });

        it('handles Apex exception gracefully', async () => {
            getNextWork.mockRejectedValue({ body: { message: 'Server error' } });
            const element = createComponent();
            emitAgent(MOCK_AGENT_CONTEXT);
            emitAssigned([]);
            await flushPromises();

            const dispatchSpy = jest.spyOn(element, 'dispatchEvent');
            const nextBtn = Array.from(element.shadowRoot.querySelectorAll('lightning-button'))
                .find(b => b.label === 'Next Best Action');
            nextBtn.click();
            await flushPromises();

            const toastCalls = dispatchSpy.mock.calls.filter(
                (call) => call[0].type === 'lightning__showtoast'
            );
            expect(toastCalls[0][0].detail.variant).toBe('error');
        });
    });

    // ── Defer Work (per-row) ────────────────────────────────────────────

    describe('defer work', () => {
        it('calls deferWork with recordId + configDevName from the row', async () => {
            deferWork.mockResolvedValue('OK');
            const element = createComponent();
            emitAgent(MOCK_AGENT_CONTEXT);
            emitAssigned([buildItem()]);
            await flushPromises();

            const deferBtn = Array.from(element.shadowRoot.querySelectorAll('lightning-button'))
                .find(b => b.label === 'Defer');
            deferBtn.click();
            await flushPromises();

            expect(deferWork).toHaveBeenCalledWith({
                recordId: '500000000000001AAA',
                configDevName: 'Test_Config'
            });
        });

        it('fires success toast on defer', async () => {
            deferWork.mockResolvedValue('OK');
            const element = createComponent();
            emitAgent(MOCK_AGENT_CONTEXT);
            emitAssigned([buildItem()]);
            await flushPromises();

            const dispatchSpy = jest.spyOn(element, 'dispatchEvent');
            const deferBtn = Array.from(element.shadowRoot.querySelectorAll('lightning-button'))
                .find(b => b.label === 'Defer');
            deferBtn.click();
            await flushPromises();

            const toastCalls = dispatchSpy.mock.calls.filter(
                (call) => call[0].type === 'lightning__showtoast'
            );
            const success = toastCalls.find(c => c[0].detail.title === 'Work Deferred');
            expect(success).not.toBeUndefined();
        });

        it('fires error toast on defer failure', async () => {
            deferWork.mockRejectedValue({ body: { message: 'Defer failed' } });
            const element = createComponent();
            emitAgent(MOCK_AGENT_CONTEXT);
            emitAssigned([buildItem()]);
            await flushPromises();

            const dispatchSpy = jest.spyOn(element, 'dispatchEvent');
            const deferBtn = Array.from(element.shadowRoot.querySelectorAll('lightning-button'))
                .find(b => b.label === 'Defer');
            deferBtn.click();
            await flushPromises();

            const toastCalls = dispatchSpy.mock.calls.filter(
                (call) => call[0].type === 'lightning__showtoast'
            );
            const err = toastCalls.find(c => c[0].detail.variant === 'error');
            expect(err).not.toBeUndefined();
        });
    });

    // ── SLA Countdown & admin-tunable colour thresholds ─────────────────

    describe('SLA countdown', () => {
        it('renders HH:MM:SS for an item with slaDeadline', async () => {
            const element = createComponent();
            emitAgent(MOCK_AGENT_CONTEXT);
            emitAssigned([buildItem()]);
            await flushPromises();

            const slaTimer = element.shadowRoot.querySelector('.sla-timer');
            expect(slaTimer.textContent).toMatch(/^\d{2}:\d{2}:\d{2}$/);
        });

        it('hides the SLA section when slaDeadline is null', async () => {
            const element = createComponent();
            emitAgent(MOCK_AGENT_CONTEXT);
            emitAssigned([buildItem({ slaDeadline: null })]);
            await flushPromises();

            expect(element.shadowRoot.querySelector('.sla-section')).toBeNull();
        });

        it('applies sla-green class when remaining > warnPct', async () => {
            const element = createComponent();
            emitAgent(MOCK_AGENT_CONTEXT);
            emitAssigned([buildItem()]); // ~91% remaining > 50%
            await flushPromises();

            expect(element.shadowRoot.querySelector('.sla-green')).not.toBeNull();
        });

        it('applies sla-amber when remaining ≤ warnPct', async () => {
            // assignedAt 80m ago, deadline 10m from now → ~11% left
            // but warnPct=90 so we land in amber band
            const now = Date.now();
            const item = buildItem({
                assignedAt: new Date(now - 80 * 60 * 1000).toISOString(),
                slaDeadline: new Date(now + 10 * 60 * 1000).toISOString(),
                slaWarnPct: 90,
                slaCriticalPct: 5
            });

            const element = createComponent();
            emitAgent(MOCK_AGENT_CONTEXT);
            emitAssigned([item]);
            await flushPromises();

            expect(element.shadowRoot.querySelector('.sla-amber')).not.toBeNull();
        });

        it('applies sla-red when remaining ≤ criticalPct (admin-tunable)', async () => {
            // 95m elapsed, 5m left → ~5% left. criticalPct=10 → red.
            const now = Date.now();
            const item = buildItem({
                assignedAt: new Date(now - 95 * 60 * 1000).toISOString(),
                slaDeadline: new Date(now + 5 * 60 * 1000).toISOString(),
                slaWarnPct: 50,
                slaCriticalPct: 10
            });

            const element = createComponent();
            emitAgent(MOCK_AGENT_CONTEXT);
            emitAssigned([item]);
            await flushPromises();

            expect(element.shadowRoot.querySelector('.sla-red')).not.toBeNull();
        });

        it('respects admin-tunable thresholds — same % different colour', async () => {
            // Item at ~30% remaining. With warnPct=50 → amber.
            // With warnPct=20 → green. Proves the CMDT value drives the class.
            const now = Date.now();
            const base = {
                assignedAt: new Date(now - 70 * 60 * 1000).toISOString(),
                slaDeadline: new Date(now + 30 * 60 * 1000).toISOString()
            };

            // Case A: warnPct=50 → amber
            const elA = createComponent();
            emitAgent(MOCK_AGENT_CONTEXT);
            emitAssigned([buildItem({ ...base, slaWarnPct: 50, slaCriticalPct: 20 })]);
            await flushPromises();
            expect(elA.shadowRoot.querySelector('.sla-amber')).not.toBeNull();
            document.body.removeChild(elA);

            // Case B: warnPct=20 → green at same %
            const elB = createComponent();
            emitAgent(MOCK_AGENT_CONTEXT);
            emitAssigned([buildItem({ ...base, slaWarnPct: 20, slaCriticalPct: 5 })]);
            await flushPromises();
            expect(elB.shadowRoot.querySelector('.sla-green')).not.toBeNull();
        });

        it('falls back to safety-net thresholds when DTO omits or inverts values', async () => {
            // warnPct <= criticalPct is an invariant violation → fallback 50/20.
            // At ~30% remaining → amber (below 50, above 20).
            const now = Date.now();
            const element = createComponent();
            emitAgent(MOCK_AGENT_CONTEXT);
            emitAssigned([buildItem({
                assignedAt: new Date(now - 70 * 60 * 1000).toISOString(),
                slaDeadline: new Date(now + 30 * 60 * 1000).toISOString(),
                slaWarnPct: 10,       // invalid: warn <= critical
                slaCriticalPct: 40
            })]);
            await flushPromises();

            expect(element.shadowRoot.querySelector('.sla-amber')).not.toBeNull();
        });

        it('shows SLA Expired when deadline is in the past', async () => {
            const element = createComponent();
            emitAgent(MOCK_AGENT_CONTEXT);
            emitAssigned([buildItem({
                assignedAt: new Date(Date.now() - 3600000).toISOString(),
                slaDeadline: new Date(Date.now() - 1000).toISOString()
            })]);
            await flushPromises();

            const slaTimer = element.shadowRoot.querySelector('.sla-timer');
            expect(slaTimer.textContent).toMatch(/(00:00:00|SLA Expired)/);
            expect(element.shadowRoot.querySelector('.sla-red')).not.toBeNull();
        });

        it('cleans up SLA timer on disconnect without throwing', async () => {
            jest.useFakeTimers();
            const element = createComponent();
            emitAgent(MOCK_AGENT_CONTEXT);
            emitAssigned([buildItem()]);

            document.body.removeChild(element);
            // Advancing timers past the 1s tick must not throw
            jest.advanceTimersByTime(5000);
            jest.useRealTimers();
        });
    });

    // ── XSS Safety ──────────────────────────────────────────────────────

    describe('XSS protection', () => {
        it('does not render HTML in record name', async () => {
            const element = createComponent();
            emitAgent(MOCK_AGENT_CONTEXT);
            emitAssigned([buildItem({ recordName: '<img src=x onerror=alert(1)>' })]);
            await flushPromises();

            const link = element.shadowRoot.querySelector('a');
            expect(link.textContent).toContain('<img src=x onerror=alert(1)>');
            expect(link.innerHTML).not.toContain('<img');
        });
    });
});
