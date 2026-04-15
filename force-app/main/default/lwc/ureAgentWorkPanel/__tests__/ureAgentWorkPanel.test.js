import { createElement } from 'lwc';
import UreAgentWorkPanel from 'c/ureAgentWorkPanel';
import getAgentContext from '@salesforce/apex/AgentWorkPanelController.getAgentContext';
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

// ── Test Data ───────────────────────────────────────────────────────────────
const MOCK_AGENT_CONTEXT = {
    agentId: 'a00000000000001AAA',
    status: 'Online',
    currentLoad: 2,
    maxCapacity: 10,
    isActive: true,
    lastAssigned: '2025-01-01T00:00:00.000Z'
};

const MOCK_WORK_SUCCESS = {
    success: true,
    recordId: '500000000000001AAA',
    recordName: 'Case-00001234',
    objectApiName: 'Case',
    assignedTo: '005000000000001AAA',
    routingLogId: 'a01000000000001AAA',
    errorMessage: null,
    slaDeadline: new Date(Date.now() + 3600000).toISOString(), // 1 hour from now
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
    return new Promise((resolve) => {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(resolve, 0);
    });
}

function createComponent() {
    const element = createElement('c-ure-agent-work-panel', { is: UreAgentWorkPanel });
    document.body.appendChild(element);
    return element;
}

function emitWiredAgent(data) {
    getAgentContext.emit(data);
}

function emitWiredAgentError() {
    getAgentContext.error();
}

// ── Test Suite ──────────────────────────────────────────────────────────────

describe('c-ure-agent-work-panel', () => {

    beforeEach(() => {
        jest.useFakeTimers();
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
        jest.useRealTimers();
    });

    // ── Initial Render / Agent Context ──────────────────────────────────

    describe('initial render with agent context', () => {
        it('renders the card with title "My Work"', async () => {
            const element = createComponent();
            emitWiredAgent(MOCK_AGENT_CONTEXT);
            await flushPromises();

            const card = element.shadowRoot.querySelector('lightning-card');
            expect(card).not.toBeNull();
            expect(card.title).toBe('My Work');
        });

        it('displays agent status badge', async () => {
            const element = createComponent();
            emitWiredAgent(MOCK_AGENT_CONTEXT);
            await flushPromises();

            const badge = element.shadowRoot.querySelector('.status-badge');
            expect(badge).not.toBeNull();
            expect(badge.textContent).toBe('Online');
        });

        it('displays current load as "2 / 10"', async () => {
            const element = createComponent();
            emitWiredAgent(MOCK_AGENT_CONTEXT);
            await flushPromises();

            const metrics = element.shadowRoot.querySelectorAll('.metric-value');
            expect(metrics.length).toBeGreaterThanOrEqual(1);
            expect(metrics[0].textContent).toBe('2 / 10');
        });

        it('renders empty state when no work assigned', async () => {
            const element = createComponent();
            emitWiredAgent(MOCK_AGENT_CONTEXT);
            await flushPromises();

            const emptyHeading = element.shadowRoot.querySelector('.empty-state .slds-text-heading_small');
            expect(emptyHeading).not.toBeNull();
            expect(emptyHeading.textContent).toBe('No Work Assigned');
        });

        it('renders Next Best Action button enabled when Online', async () => {
            const element = createComponent();
            emitWiredAgent(MOCK_AGENT_CONTEXT);
            await flushPromises();

            const buttons = element.shadowRoot.querySelectorAll('lightning-button');
            const nextBtn = Array.from(buttons).find(b => b.label === 'Next Best Action');
            expect(nextBtn).not.toBeNull();
            expect(nextBtn.disabled).toBe(false);
        });
    });

    // ── Agent Error State ───────────────────────────────────────────────

    describe('agent error state', () => {
        it('renders error illustration when no agent record exists', async () => {
            const element = createComponent();
            emitWiredAgentError();
            await flushPromises();

            const illustration = element.shadowRoot.querySelector('lightning-illustration');
            expect(illustration).not.toBeNull();
        });

        it('does not render Next Best Action button on agent error', async () => {
            const element = createComponent();
            emitWiredAgentError();
            await flushPromises();

            const buttons = element.shadowRoot.querySelectorAll('lightning-button');
            expect(buttons.length).toBe(0);
        });
    });

    // ── Availability Toggle ─────────────────────────────────────────────

    describe('availability toggle', () => {
        it('renders combobox with current status', async () => {
            const element = createComponent();
            emitWiredAgent(MOCK_AGENT_CONTEXT);
            await flushPromises();

            const combo = element.shadowRoot.querySelector('lightning-combobox');
            expect(combo).not.toBeNull();
            expect(combo.value).toBe('Online');
        });

        it('disables Next Best Action when status is Away', async () => {
            const element = createComponent();
            emitWiredAgent({ ...MOCK_AGENT_CONTEXT, status: 'Away' });
            await flushPromises();

            const buttons = element.shadowRoot.querySelectorAll('lightning-button');
            const nextBtn = Array.from(buttons).find(b => b.label === 'Next Best Action');
            expect(nextBtn.disabled).toBe(true);
        });

        it('disables Next Best Action when status is Offline', async () => {
            const element = createComponent();
            emitWiredAgent({ ...MOCK_AGENT_CONTEXT, status: 'Offline' });
            await flushPromises();

            const buttons = element.shadowRoot.querySelectorAll('lightning-button');
            const nextBtn = Array.from(buttons).find(b => b.label === 'Next Best Action');
            expect(nextBtn.disabled).toBe(true);
        });

        it('calls updateAgentStatus on combobox change', async () => {
            updateAgentStatus.mockResolvedValue('OK');
            const element = createComponent();
            emitWiredAgent(MOCK_AGENT_CONTEXT);
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
        it('displays assigned record on success', async () => {
            getNextWork.mockResolvedValue(MOCK_WORK_SUCCESS);
            const element = createComponent();
            emitWiredAgent(MOCK_AGENT_CONTEXT);
            await flushPromises();

            const nextBtn = Array.from(
                element.shadowRoot.querySelectorAll('lightning-button')
            ).find(b => b.label === 'Next Best Action');

            nextBtn.click();
            await flushPromises();

            const link = element.shadowRoot.querySelector('a');
            expect(link).not.toBeNull();
            expect(link.textContent).toContain('Case-00001234');
        });

        it('shows defer button when work is assigned', async () => {
            getNextWork.mockResolvedValue(MOCK_WORK_SUCCESS);
            const element = createComponent();
            emitWiredAgent(MOCK_AGENT_CONTEXT);
            await flushPromises();

            const nextBtn = Array.from(
                element.shadowRoot.querySelectorAll('lightning-button')
            ).find(b => b.label === 'Next Best Action');

            nextBtn.click();
            await flushPromises();

            const deferBtn = Array.from(
                element.shadowRoot.querySelectorAll('lightning-button')
            ).find(b => b.label === 'Defer');
            expect(deferBtn).not.toBeNull();
        });

        it('fires success toast on work assignment', async () => {
            getNextWork.mockResolvedValue(MOCK_WORK_SUCCESS);
            const element = createComponent();
            emitWiredAgent(MOCK_AGENT_CONTEXT);
            await flushPromises();

            const dispatchSpy = jest.spyOn(element, 'dispatchEvent');
            const nextBtn = Array.from(
                element.shadowRoot.querySelectorAll('lightning-button')
            ).find(b => b.label === 'Next Best Action');

            nextBtn.click();
            await flushPromises();

            const toastCalls = dispatchSpy.mock.calls.filter(
                (call) => call[0].type === 'lightning__showtoast'
            );
            expect(toastCalls.length).toBeGreaterThanOrEqual(1);
            expect(toastCalls[0][0].detail.variant).toBe('success');
        });

        it('shows warning toast on no-match', async () => {
            getNextWork.mockResolvedValue(MOCK_WORK_NO_MATCH);
            const element = createComponent();
            emitWiredAgent(MOCK_AGENT_CONTEXT);
            await flushPromises();

            const dispatchSpy = jest.spyOn(element, 'dispatchEvent');
            const nextBtn = Array.from(
                element.shadowRoot.querySelectorAll('lightning-button')
            ).find(b => b.label === 'Next Best Action');

            nextBtn.click();
            await flushPromises();

            const toastCalls = dispatchSpy.mock.calls.filter(
                (call) => call[0].type === 'lightning__showtoast'
            );
            expect(toastCalls.length).toBeGreaterThanOrEqual(1);
            expect(toastCalls[0][0].detail.variant).toBe('warning');
        });

        it('handles Apex exception gracefully', async () => {
            getNextWork.mockRejectedValue({ body: { message: 'Server error' } });
            const element = createComponent();
            emitWiredAgent(MOCK_AGENT_CONTEXT);
            await flushPromises();

            const dispatchSpy = jest.spyOn(element, 'dispatchEvent');
            const nextBtn = Array.from(
                element.shadowRoot.querySelectorAll('lightning-button')
            ).find(b => b.label === 'Next Best Action');

            nextBtn.click();
            await flushPromises();

            const toastCalls = dispatchSpy.mock.calls.filter(
                (call) => call[0].type === 'lightning__showtoast'
            );
            expect(toastCalls.length).toBeGreaterThanOrEqual(1);
            expect(toastCalls[0][0].detail.variant).toBe('error');
        });
    });

    // ── Defer Work ──────────────────────────────────────────────────────

    describe('defer work', () => {
        it('clears current work on successful defer', async () => {
            getNextWork.mockResolvedValue(MOCK_WORK_SUCCESS);
            deferWork.mockResolvedValue('OK');
            const element = createComponent();
            emitWiredAgent(MOCK_AGENT_CONTEXT);
            await flushPromises();

            // First, get work
            const nextBtn = Array.from(
                element.shadowRoot.querySelectorAll('lightning-button')
            ).find(b => b.label === 'Next Best Action');
            nextBtn.click();
            await flushPromises();

            // Now defer
            const deferBtn = Array.from(
                element.shadowRoot.querySelectorAll('lightning-button')
            ).find(b => b.label === 'Defer');
            deferBtn.click();
            await flushPromises();

            // Work should be cleared, empty state should return
            const link = element.shadowRoot.querySelector('a');
            expect(link).toBeNull();

            const emptyHeading = element.shadowRoot.querySelector('.empty-state');
            expect(emptyHeading).not.toBeNull();
        });

        it('fires success toast on defer', async () => {
            getNextWork.mockResolvedValue(MOCK_WORK_SUCCESS);
            deferWork.mockResolvedValue('OK');
            const element = createComponent();
            emitWiredAgent(MOCK_AGENT_CONTEXT);
            await flushPromises();

            const nextBtn = Array.from(
                element.shadowRoot.querySelectorAll('lightning-button')
            ).find(b => b.label === 'Next Best Action');
            nextBtn.click();
            await flushPromises();

            const dispatchSpy = jest.spyOn(element, 'dispatchEvent');
            const deferBtn = Array.from(
                element.shadowRoot.querySelectorAll('lightning-button')
            ).find(b => b.label === 'Defer');
            deferBtn.click();
            await flushPromises();

            const toastCalls = dispatchSpy.mock.calls.filter(
                (call) => call[0].type === 'lightning__showtoast'
            );
            const successToast = toastCalls.find(c => c[0].detail.title === 'Work Deferred');
            expect(successToast).not.toBeUndefined();
        });

        it('fires error toast on defer failure', async () => {
            getNextWork.mockResolvedValue(MOCK_WORK_SUCCESS);
            deferWork.mockRejectedValue({ body: { message: 'Defer failed' } });
            const element = createComponent();
            emitWiredAgent(MOCK_AGENT_CONTEXT);
            await flushPromises();

            const nextBtn = Array.from(
                element.shadowRoot.querySelectorAll('lightning-button')
            ).find(b => b.label === 'Next Best Action');
            nextBtn.click();
            await flushPromises();

            const dispatchSpy = jest.spyOn(element, 'dispatchEvent');
            const deferBtn = Array.from(
                element.shadowRoot.querySelectorAll('lightning-button')
            ).find(b => b.label === 'Defer');
            deferBtn.click();
            await flushPromises();

            const toastCalls = dispatchSpy.mock.calls.filter(
                (call) => call[0].type === 'lightning__showtoast'
            );
            const errorToast = toastCalls.find(c => c[0].detail.variant === 'error');
            expect(errorToast).not.toBeUndefined();
        });
    });

    // ── SLA Countdown ───────────────────────────────────────────────────

    describe('SLA countdown timer', () => {
        it('displays SLA countdown when work has slaDeadline', async () => {
            getNextWork.mockResolvedValue(MOCK_WORK_SUCCESS);
            const element = createComponent();
            emitWiredAgent(MOCK_AGENT_CONTEXT);
            await flushPromises();

            const nextBtn = Array.from(
                element.shadowRoot.querySelectorAll('lightning-button')
            ).find(b => b.label === 'Next Best Action');
            nextBtn.click();
            await flushPromises();

            const slaTimer = element.shadowRoot.querySelector('.sla-timer');
            expect(slaTimer).not.toBeNull();
            // Should display HH:MM:SS format
            expect(slaTimer.textContent).toMatch(/^\d{2}:\d{2}:\d{2}$/);
        });

        it('does not display SLA section when slaDeadline is null', async () => {
            const noSlaWork = { ...MOCK_WORK_SUCCESS, slaDeadline: null };
            getNextWork.mockResolvedValue(noSlaWork);
            const element = createComponent();
            emitWiredAgent(MOCK_AGENT_CONTEXT);
            await flushPromises();

            const nextBtn = Array.from(
                element.shadowRoot.querySelectorAll('lightning-button')
            ).find(b => b.label === 'Next Best Action');
            nextBtn.click();
            await flushPromises();

            const slaSection = element.shadowRoot.querySelector('.sla-section');
            expect(slaSection).toBeNull();
        });

        it('applies sla-green class when > 50% remaining', async () => {
            // 1 hour from now = well above 50%
            getNextWork.mockResolvedValue(MOCK_WORK_SUCCESS);
            const element = createComponent();
            emitWiredAgent(MOCK_AGENT_CONTEXT);
            await flushPromises();

            const nextBtn = Array.from(
                element.shadowRoot.querySelectorAll('lightning-button')
            ).find(b => b.label === 'Next Best Action');
            nextBtn.click();
            await flushPromises();

            const slaDiv = element.shadowRoot.querySelector('.sla-green');
            expect(slaDiv).not.toBeNull();
        });

        it('shows SLA Expired when deadline is in the past', async () => {
            const expiredWork = {
                ...MOCK_WORK_SUCCESS,
                slaDeadline: new Date(Date.now() - 1000).toISOString()
            };
            getNextWork.mockResolvedValue(expiredWork);
            const element = createComponent();
            emitWiredAgent(MOCK_AGENT_CONTEXT);
            await flushPromises();

            const nextBtn = Array.from(
                element.shadowRoot.querySelectorAll('lightning-button')
            ).find(b => b.label === 'Next Best Action');
            nextBtn.click();
            await flushPromises();

            const slaTimer = element.shadowRoot.querySelector('.sla-timer');
            expect(slaTimer).not.toBeNull();
            // Should show expired state
            expect(slaTimer.textContent).toMatch(/(00:00:00|SLA Expired)/);
        });

        it('clears SLA timer on disconnectedCallback', async () => {
            getNextWork.mockResolvedValue(MOCK_WORK_SUCCESS);
            const element = createComponent();
            emitWiredAgent(MOCK_AGENT_CONTEXT);
            await flushPromises();

            const nextBtn = Array.from(
                element.shadowRoot.querySelectorAll('lightning-button')
            ).find(b => b.label === 'Next Best Action');
            nextBtn.click();
            await flushPromises();

            // Remove component — should clear interval
            document.body.removeChild(element);

            // Advance timers — should not throw
            jest.advanceTimersByTime(5000);
        });

        it('clears SLA timer when work is deferred', async () => {
            getNextWork.mockResolvedValue(MOCK_WORK_SUCCESS);
            deferWork.mockResolvedValue('OK');
            const element = createComponent();
            emitWiredAgent(MOCK_AGENT_CONTEXT);
            await flushPromises();

            const nextBtn = Array.from(
                element.shadowRoot.querySelectorAll('lightning-button')
            ).find(b => b.label === 'Next Best Action');
            nextBtn.click();
            await flushPromises();

            const deferBtn = Array.from(
                element.shadowRoot.querySelectorAll('lightning-button')
            ).find(b => b.label === 'Defer');
            deferBtn.click();
            await flushPromises();

            // SLA section should be gone
            const slaSection = element.shadowRoot.querySelector('.sla-section');
            expect(slaSection).toBeNull();
        });
    });

    // ── XSS Safety ──────────────────────────────────────────────────────

    describe('XSS protection', () => {
        it('does not render HTML in record name', async () => {
            const xssWork = {
                ...MOCK_WORK_SUCCESS,
                recordName: '<img src=x onerror=alert(1)>'
            };
            getNextWork.mockResolvedValue(xssWork);
            const element = createComponent();
            emitWiredAgent(MOCK_AGENT_CONTEXT);
            await flushPromises();

            const nextBtn = Array.from(
                element.shadowRoot.querySelectorAll('lightning-button')
            ).find(b => b.label === 'Next Best Action');
            nextBtn.click();
            await flushPromises();

            const link = element.shadowRoot.querySelector('a');
            expect(link.textContent).toContain('<img src=x onerror=alert(1)>');
            expect(link.innerHTML).not.toContain('<img');
        });
    });
});
