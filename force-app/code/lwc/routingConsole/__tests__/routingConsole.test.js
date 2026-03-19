import { createElement } from 'lwc';
import RoutingConsole from 'c/routingConsole';
import getNextRecord from '@salesforce/apex/RoutingService.getNextRecord';

// ── Mock Apex ────────────────────────────────────────────────────────────────
jest.mock(
    '@salesforce/apex/RoutingService.getNextRecord',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

// ── Mock Custom Labels ───────────────────────────────────────────────────────
jest.mock('@salesforce/label/c.URE_NextBestAction', () => ({ default: 'Next Best Action' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_Routing', () => ({ default: 'Routing...' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_Assigned', () => ({ default: 'Assigned' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_RecordAssigned', () => ({ default: 'Record Assigned' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_RoutingError', () => ({ default: 'Routing Error' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_NoRecordsAvailable', () => ({ default: 'No records available.' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_UnexpectedError', () => ({ default: 'An unexpected error occurred.' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_FindingNextRecord', () => ({ default: 'Finding next record' }), { virtual: true });

// ── Mock NavigationMixin ─────────────────────────────────────────────────────
const MOCK_RECORD_URL = '/lightning/r/Case/500000000000001AAA/view';

// ── Test Data ────────────────────────────────────────────────────────────────
const MOCK_SUCCESS_RESULT = {
    recordId: '500000000000001AAA',
    success: true,
    assignedTo: '005000000000001AAA',
    routingLogId: 'a00000000000001AAA',
    errorMessage: null,
    objectApiName: 'Case',
    recordName: 'Case-00001234',
    entryPoint: 'LWC',
    retryCount: 1
};

const MOCK_NO_MATCH_RESULT = {
    recordId: null,
    success: false,
    assignedTo: null,
    routingLogId: null,
    errorMessage: 'No matching candidates found.',
    objectApiName: null,
    recordName: null,
    entryPoint: 'LWC',
    retryCount: 0
};

const MOCK_FAILURE_RESULT = {
    recordId: null,
    success: false,
    assignedTo: null,
    routingLogId: null,
    errorMessage: 'No active routing configurations found.',
    objectApiName: null,
    recordName: null,
    entryPoint: 'LWC',
    retryCount: 0
};

// ── Helpers ──────────────────────────────────────────────────────────────────

/** Flush all pending microtasks (Promises) */
async function flushPromises() {
    return new Promise((resolve) => {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(resolve, 0);
    });
}

function createComponent() {
    const element = createElement('c-routing-console', { is: RoutingConsole });
    document.body.appendChild(element);
    return element;
}

// ── Test Suite ───────────────────────────────────────────────────────────────

describe('c-routing-console', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    // ── Rendering ────────────────────────────────────────────────────────

    describe('initial render', () => {
        it('renders the Next Best Action button with correct label', () => {
            const element = createComponent();
            const button = element.shadowRoot.querySelector('lightning-button');

            expect(button).not.toBeNull();
            expect(button.label).toBe('Next Best Action');
            expect(button.variant).toBe('brand');
            expect(button.disabled).toBe(false);
        });

        it('does NOT call Apex on load — human-initiated only', () => {
            createComponent();
            expect(getNextRecord).not.toHaveBeenCalled();
        });

        it('does not render success or failure sections initially', () => {
            const element = createComponent();
            const link = element.shadowRoot.querySelector('a');
            const icons = element.shadowRoot.querySelectorAll('lightning-icon');

            expect(link).toBeNull();
            expect(icons.length).toBe(0);
        });

        it('does not render a loading spinner initially', () => {
            const element = createComponent();
            const spinner = element.shadowRoot.querySelector('lightning-spinner');
            expect(spinner).toBeNull();
        });
    });

    // ── Successful Routing ───────────────────────────────────────────────

    describe('successful routing', () => {
        it('calls Apex with null params on button click', async () => {
            getNextRecord.mockResolvedValue(MOCK_SUCCESS_RESULT);
            const element = createComponent();

            const button = element.shadowRoot.querySelector('lightning-button');
            button.click();
            await flushPromises();

            expect(getNextRecord).toHaveBeenCalledWith({
                objectApiName: null,
                recordId: null,
                configDeveloperName: null
            });
        });

        it('displays record name as clickable link on success', async () => {
            getNextRecord.mockResolvedValue(MOCK_SUCCESS_RESULT);
            const element = createComponent();

            element.shadowRoot.querySelector('lightning-button').click();
            await flushPromises();

            const link = element.shadowRoot.querySelector('a');
            expect(link).not.toBeNull();
            expect(link.textContent).toBe('Case-00001234');
        });

        it('shows success icon on successful assignment', async () => {
            getNextRecord.mockResolvedValue(MOCK_SUCCESS_RESULT);
            const element = createComponent();

            element.shadowRoot.querySelector('lightning-button').click();
            await flushPromises();

            const icon = element.shadowRoot.querySelector('lightning-icon');
            expect(icon).not.toBeNull();
            expect(icon.iconName).toBe('utility:success');
            expect(icon.variant).toBe('success');
        });

        it('displays "Assigned" label above the record link', async () => {
            getNextRecord.mockResolvedValue(MOCK_SUCCESS_RESULT);
            const element = createComponent();

            element.shadowRoot.querySelector('lightning-button').click();
            await flushPromises();

            const label = element.shadowRoot.querySelector('p.slds-text-color_weak');
            expect(label).not.toBeNull();
            expect(label.textContent).toBe('Assigned');
        });

        it('fires success toast with record name', async () => {
            getNextRecord.mockResolvedValue(MOCK_SUCCESS_RESULT);
            const element = createComponent();
            const dispatchSpy = jest.spyOn(element, 'dispatchEvent');

            element.shadowRoot.querySelector('lightning-button').click();
            await flushPromises();

            const toastCalls = dispatchSpy.mock.calls.filter(
                (call) => call[0].type === 'lightning__showtoast'
            );
            expect(toastCalls).toHaveLength(1);
            expect(toastCalls[0][0].detail.title).toBe('Record Assigned');
            expect(toastCalls[0][0].detail.message).toBe('Case-00001234');
            expect(toastCalls[0][0].detail.variant).toBe('success');
        });

        it('falls back to recordId when recordName is null', async () => {
            const resultNoName = { ...MOCK_SUCCESS_RESULT, recordName: null };
            getNextRecord.mockResolvedValue(resultNoName);
            const element = createComponent();

            element.shadowRoot.querySelector('lightning-button').click();
            await flushPromises();

            const link = element.shadowRoot.querySelector('a');
            expect(link.textContent).toBe('500000000000001AAA');
        });
    });

    // ── No Match / Failure ───────────────────────────────────────────────

    describe('no match and failure states', () => {
        it('displays error message when no candidates found', async () => {
            getNextRecord.mockResolvedValue(MOCK_NO_MATCH_RESULT);
            const element = createComponent();

            element.shadowRoot.querySelector('lightning-button').click();
            await flushPromises();

            const message = element.shadowRoot.querySelector('p.slds-text-body_small');
            expect(message).not.toBeNull();
            expect(message.textContent).toBe('No matching candidates found.');
        });

        it('shows warning icon on failure', async () => {
            getNextRecord.mockResolvedValue(MOCK_FAILURE_RESULT);
            const element = createComponent();

            element.shadowRoot.querySelector('lightning-button').click();
            await flushPromises();

            const icon = element.shadowRoot.querySelector('lightning-icon');
            expect(icon).not.toBeNull();
            expect(icon.iconName).toBe('utility:warning');
            expect(icon.variant).toBe('warning');
        });

        it('does not render a record link on failure', async () => {
            getNextRecord.mockResolvedValue(MOCK_FAILURE_RESULT);
            const element = createComponent();

            element.shadowRoot.querySelector('lightning-button').click();
            await flushPromises();

            const link = element.shadowRoot.querySelector('a');
            expect(link).toBeNull();
        });

        it('uses custom label fallback when errorMessage is null', async () => {
            const resultNoError = { ...MOCK_FAILURE_RESULT, errorMessage: null };
            getNextRecord.mockResolvedValue(resultNoError);
            const element = createComponent();

            element.shadowRoot.querySelector('lightning-button').click();
            await flushPromises();

            const message = element.shadowRoot.querySelector('p.slds-text-body_small');
            expect(message.textContent).toBe('No records available.');
        });
    });

    // ── Network / Apex Exception ─────────────────────────────────────────

    describe('Apex exception handling', () => {
        it('handles Apex exception with structured error body', async () => {
            getNextRecord.mockRejectedValue({
                body: { message: 'Session expired' }
            });
            const element = createComponent();

            element.shadowRoot.querySelector('lightning-button').click();
            await flushPromises();

            const message = element.shadowRoot.querySelector('p.slds-text-body_small');
            expect(message).not.toBeNull();
            expect(message.textContent).toBe('Session expired');
        });

        it('falls back to custom label on unstructured error', async () => {
            getNextRecord.mockRejectedValue(new Error('Network failure'));
            const element = createComponent();

            element.shadowRoot.querySelector('lightning-button').click();
            await flushPromises();

            const message = element.shadowRoot.querySelector('p.slds-text-body_small');
            expect(message.textContent).toBe('An unexpected error occurred.');
        });

        it('fires error toast on Apex exception', async () => {
            getNextRecord.mockRejectedValue({
                body: { message: 'Internal error' }
            });
            const element = createComponent();
            const dispatchSpy = jest.spyOn(element, 'dispatchEvent');

            element.shadowRoot.querySelector('lightning-button').click();
            await flushPromises();

            const toastCalls = dispatchSpy.mock.calls.filter(
                (call) => call[0].type === 'lightning__showtoast'
            );
            expect(toastCalls).toHaveLength(1);
            expect(toastCalls[0][0].detail.title).toBe('Routing Error');
            expect(toastCalls[0][0].detail.variant).toBe('error');
        });
    });

    // ── Button State ─────────────────────────────────────────────────────

    describe('button state management', () => {
        it('re-enables button after successful routing', async () => {
            getNextRecord.mockResolvedValue(MOCK_SUCCESS_RESULT);
            const element = createComponent();

            element.shadowRoot.querySelector('lightning-button').click();
            await flushPromises();

            const button = element.shadowRoot.querySelector('lightning-button');
            expect(button.disabled).toBe(false);
            expect(button.label).toBe('Next Best Action');
        });

        it('re-enables button after failed routing', async () => {
            getNextRecord.mockResolvedValue(MOCK_FAILURE_RESULT);
            const element = createComponent();

            element.shadowRoot.querySelector('lightning-button').click();
            await flushPromises();

            const button = element.shadowRoot.querySelector('lightning-button');
            expect(button.disabled).toBe(false);
        });

        it('re-enables button after Apex exception', async () => {
            getNextRecord.mockRejectedValue(new Error('fail'));
            const element = createComponent();

            element.shadowRoot.querySelector('lightning-button').click();
            await flushPromises();

            const button = element.shadowRoot.querySelector('lightning-button');
            expect(button.disabled).toBe(false);
        });
    });

    // ── Navigation ───────────────────────────────────────────────────────

    describe('record navigation', () => {
        it('prevents default anchor behavior on link click', async () => {
            getNextRecord.mockResolvedValue(MOCK_SUCCESS_RESULT);
            const element = createComponent();

            element.shadowRoot.querySelector('lightning-button').click();
            await flushPromises();

            const link = element.shadowRoot.querySelector('a');
            const clickEvent = new CustomEvent('click', {
                bubbles: true,
                cancelable: true
            });
            link.dispatchEvent(clickEvent);

            expect(clickEvent.defaultPrevented).toBe(true);
        });
    });

    // ── Subsequent Clicks (overwrite previous result) ────────────────────

    describe('subsequent routing calls', () => {
        it('replaces previous result with new success', async () => {
            getNextRecord.mockResolvedValueOnce(MOCK_SUCCESS_RESULT);
            const element = createComponent();

            element.shadowRoot.querySelector('lightning-button').click();
            await flushPromises();

            const secondResult = {
                ...MOCK_SUCCESS_RESULT,
                recordId: '500000000000002AAA',
                recordName: 'Case-00005678'
            };
            getNextRecord.mockResolvedValueOnce(secondResult);

            element.shadowRoot.querySelector('lightning-button').click();
            await flushPromises();

            const link = element.shadowRoot.querySelector('a');
            expect(link.textContent).toBe('Case-00005678');
        });

        it('replaces previous success with failure', async () => {
            getNextRecord.mockResolvedValueOnce(MOCK_SUCCESS_RESULT);
            const element = createComponent();

            element.shadowRoot.querySelector('lightning-button').click();
            await flushPromises();

            getNextRecord.mockResolvedValueOnce(MOCK_NO_MATCH_RESULT);

            element.shadowRoot.querySelector('lightning-button').click();
            await flushPromises();

            const link = element.shadowRoot.querySelector('a');
            expect(link).toBeNull();

            const message = element.shadowRoot.querySelector('p.slds-text-body_small');
            expect(message.textContent).toBe('No matching candidates found.');
        });
    });

    // ── XSS Safety ───────────────────────────────────────────────────────

    describe('XSS protection', () => {
        it('does not render HTML in record name — text content only', async () => {
            const xssResult = {
                ...MOCK_SUCCESS_RESULT,
                recordName: '<img src=x onerror=alert(1)>'
            };
            getNextRecord.mockResolvedValue(xssResult);
            const element = createComponent();

            element.shadowRoot.querySelector('lightning-button').click();
            await flushPromises();

            const link = element.shadowRoot.querySelector('a');
            // LWC template expressions render as text, not HTML
            expect(link.textContent).toBe('<img src=x onerror=alert(1)>');
            expect(link.innerHTML).not.toContain('<img');
        });

        it('does not render HTML in error messages', async () => {
            const xssResult = {
                ...MOCK_FAILURE_RESULT,
                errorMessage: '<script>alert("xss")</script>'
            };
            getNextRecord.mockResolvedValue(xssResult);
            const element = createComponent();

            element.shadowRoot.querySelector('lightning-button').click();
            await flushPromises();

            const message = element.shadowRoot.querySelector('p.slds-text-body_small');
            expect(message.textContent).toBe('<script>alert("xss")</script>');
            expect(message.innerHTML).not.toContain('<script');
        });
    });
});
