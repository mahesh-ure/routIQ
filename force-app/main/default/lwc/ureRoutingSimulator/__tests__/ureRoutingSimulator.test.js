import { createElement } from 'lwc';
import UreRoutingSimulator from 'c/ureRoutingSimulator';
import getActiveConfigs from '@salesforce/apex/RoutingSimulatorController.getActiveConfigs';
import simulateRouting from '@salesforce/apex/RoutingSimulatorController.simulateRouting';

// Mock the Apex calls
jest.mock(
    '@salesforce/apex/RoutingSimulatorController.getActiveConfigs',
    () => {
        return { default: jest.fn() };
    },
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/RoutingSimulatorController.simulateRouting',
    () => {
        return { default: jest.fn() };
    },
    { virtual: true }
);

// Mock Custom Labels
jest.mock('@salesforce/label/c.URE_WizardConfigNameLabel', () => ({ default: 'Configuration Name' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_WizardRecordIdLabel', () => ({ default: 'Sample Record ID' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_WizardRecordIdHelp', () => ({ default: 'Enter the ID of an existing record' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_WizardSimulate', () => ({ default: 'Simulate' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_WizardSimulationResult', () => ({ default: 'Simulation Results' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_WizardConditionTraces', () => ({ default: 'Condition Evaluation Details' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_WizardSimulating', () => ({ default: 'Running simulation' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_WizardSampleRecordError', () => ({ default: 'Please enter a sample record ID.' }), { virtual: true });
jest.mock('@salesforce/label/c.URE_WizardSimulationFailed', () => ({ default: 'Simulation failed.' }), { virtual: true });

describe('c-ure-routing-simulator', () => {

    afterEach(() => {
        // Clear all mocks after each test
        jest.clearAllMocks();
    });

    // ─── Component Initialization ────────────────────────────────────────

    describe('initialization', () => {

        it('loads active configs on connectedCallback', async () => {
            const mockConfigs = [
                { developerName: 'Case_Routing', label: 'Case Routing', objectApiName: 'Case' },
                { developerName: 'Lead_Routing', label: 'Lead Routing', objectApiName: 'Lead' }
            ];
            getActiveConfigs.mockResolvedValue(mockConfigs);

            const element = createElement('c-ure-routing-simulator', { is: UreRoutingSimulator });
            document.body.appendChild(element);

            await new Promise(resolve => setTimeout(resolve, 0));
            expect(getActiveConfigs).toHaveBeenCalled();

            document.body.removeChild(element);
        });

        it('handles config load error gracefully', async () => {
            getActiveConfigs.mockRejectedValue(new Error('Network error'));

            const element = createElement('c-ure-routing-simulator', { is: UreRoutingSimulator });
            document.body.appendChild(element);

            await new Promise(resolve => setTimeout(resolve, 0));
            expect(element.configsError).toContain('Failed to load configurations');

            document.body.removeChild(element);
        });

    });

    // ─── Config Selection ───────────────────────────────────────────────

    describe('config selection', () => {

        it('updates selectedConfigDevName on config change', async () => {
            getActiveConfigs.mockResolvedValue([
                { developerName: 'Case_Routing', label: 'Case Routing', objectApiName: 'Case' }
            ]);

            const element = createElement('c-ure-routing-simulator', { is: UreRoutingSimulator });
            document.body.appendChild(element);

            await new Promise(resolve => setTimeout(resolve, 0));

            element.selectedConfigDevName = 'Case_Routing';
            expect(element.selectedConfigDevName).toBe('Case_Routing');

            document.body.removeChild(element);
        });

        it('clears simulation result when config changes', async () => {
            getActiveConfigs.mockResolvedValue([
                { developerName: 'Case_Routing', label: 'Case Routing', objectApiName: 'Case' }
            ]);

            const element = createElement('c-ure-routing-simulator', { is: UreRoutingSimulator });
            document.body.appendChild(element);

            await new Promise(resolve => setTimeout(resolve, 0));

            element.simulateResult = { success: true };
            element.selectedConfigDevName = 'Case_Routing';

            expect(element.simulateResult).toBeNull();

            document.body.removeChild(element);
        });

    });

    // ─── Record ID Input ────────────────────────────────────────────────

    describe('record id input', () => {

        it('updates recordId on input change', async () => {
            getActiveConfigs.mockResolvedValue([]);

            const element = createElement('c-ure-routing-simulator', { is: UreRoutingSimulator });
            document.body.appendChild(element);

            await new Promise(resolve => setTimeout(resolve, 0));

            element.recordId = '500xx0000001234';
            expect(element.recordId).toBe('500xx0000001234');

            document.body.removeChild(element);
        });

        it('clears simulation result when record ID changes', async () => {
            getActiveConfigs.mockResolvedValue([]);

            const element = createElement('c-ure-routing-simulator', { is: UreRoutingSimulator });
            document.body.appendChild(element);

            await new Promise(resolve => setTimeout(resolve, 0));

            element.simulateResult = { success: false };
            element.recordId = '500xx0000001234';

            expect(element.simulateResult).toBeNull();

            document.body.removeChild(element);
        });

    });

    // ─── Simulation ──────────────────────────────────────────────────────

    describe('simulation', () => {

        it('requires both config and record ID', async () => {
            getActiveConfigs.mockResolvedValue([]);

            const element = createElement('c-ure-routing-simulator', { is: UreRoutingSimulator });
            document.body.appendChild(element);

            await new Promise(resolve => setTimeout(resolve, 0));

            // Try without config
            element.recordId = '500xx0000001234';
            element.selectedConfigDevName = '';
            await element.handleSimulate();
            expect(element.simulateError).toContain('configuration');

            // Try without record ID
            element.recordId = '';
            element.selectedConfigDevName = 'Case_Routing';
            await element.handleSimulate();
            expect(element.simulateError).toBeTruthy();

            document.body.removeChild(element);
        });

        it('calls simulateRouting with correct parameters', async () => {
            const mockResult = {
                success: true,
                reasonSummary: 'Match found',
                conditionTraces: [],
                errorMessage: null
            };
            getActiveConfigs.mockResolvedValue([]);
            simulateRouting.mockResolvedValue(mockResult);

            const element = createElement('c-ure-routing-simulator', { is: UreRoutingSimulator });
            document.body.appendChild(element);

            await new Promise(resolve => setTimeout(resolve, 0));

            element.recordId = '500xx0000001234';
            element.selectedConfigDevName = 'Case_Routing';

            await element.handleSimulate();

            expect(simulateRouting).toHaveBeenCalledWith({
                recordId: '500xx0000001234',
                configDeveloperName: 'Case_Routing'
            });

            document.body.removeChild(element);
        });

        it('displays success result with condition traces', async () => {
            const mockResult = {
                success: true,
                reasonSummary: 'Assigned to Agent A',
                conditionTraces: [
                    {
                        fieldApiName: 'Priority',
                        operator: 'EQUALS',
                        expectedValue: 'High',
                        actualValue: 'High',
                        passed: true
                    },
                    {
                        fieldApiName: 'Status',
                        operator: 'IN',
                        expectedValue: 'Open,New',
                        actualValue: 'Open',
                        passed: true
                    }
                ],
                errorMessage: null
            };
            getActiveConfigs.mockResolvedValue([]);
            simulateRouting.mockResolvedValue(mockResult);

            const element = createElement('c-ure-routing-simulator', { is: UreRoutingSimulator });
            document.body.appendChild(element);

            await new Promise(resolve => setTimeout(resolve, 0));

            element.recordId = '500xx0000001234';
            element.selectedConfigDevName = 'Case_Routing';

            await element.handleSimulate();

            expect(element.simulateSuccess).toBe(true);
            expect(element.reasonSummary).toBe('Assigned to Agent A');
            expect(element.conditionTraces.length).toBe(2);
            expect(element.conditionTraces[0].passed).toBe(true);

            document.body.removeChild(element);
        });

        it('displays no-match result with condition failures', async () => {
            const mockResult = {
                success: false,
                reasonSummary: 'No matching candidates found',
                conditionTraces: [
                    {
                        fieldApiName: 'Priority',
                        operator: 'EQUALS',
                        expectedValue: 'Urgent',
                        actualValue: 'High',
                        passed: false
                    }
                ],
                errorMessage: 'No matching candidates'
            };
            getActiveConfigs.mockResolvedValue([]);
            simulateRouting.mockResolvedValue(mockResult);

            const element = createElement('c-ure-routing-simulator', { is: UreRoutingSimulator });
            document.body.appendChild(element);

            await new Promise(resolve => setTimeout(resolve, 0));

            element.recordId = '500xx0000001234';
            element.selectedConfigDevName = 'Case_Routing';

            await element.handleSimulate();

            expect(element.simulateSuccess).toBe(false);
            expect(element.resultTitle).toBe('No Match');
            expect(element.hasTraces).toBe(true);

            document.body.removeChild(element);
        });

        it('handles simulation error', async () => {
            const mockError = new Error('Invalid record ID');
            mockError.body = { message: 'Record not found' };
            getActiveConfigs.mockResolvedValue([]);
            simulateRouting.mockRejectedValue(mockError);

            const element = createElement('c-ure-routing-simulator', { is: UreRoutingSimulator });
            document.body.appendChild(element);

            await new Promise(resolve => setTimeout(resolve, 0));

            element.recordId = '500xx0000001234';
            element.selectedConfigDevName = 'Case_Routing';

            await element.handleSimulate();

            expect(element.simulateError).toBe('Record not found');

            document.body.removeChild(element);
        });

    });

    // ─── Computed Properties ────────────────────────────────────────────

    describe('computed properties', () => {

        it('isSimulateDisabled when no config selected', async () => {
            getActiveConfigs.mockResolvedValue([
                { developerName: 'Case_Routing', label: 'Case Routing', objectApiName: 'Case' }
            ]);

            const element = createElement('c-ure-routing-simulator', { is: UreRoutingSimulator });
            document.body.appendChild(element);

            await new Promise(resolve => setTimeout(resolve, 0));

            element.selectedConfigDevName = '';
            expect(element.isSimulateDisabled).toBe(true);

            document.body.removeChild(element);
        });

        it('isSimulateDisabled when simulating', async () => {
            getActiveConfigs.mockResolvedValue([]);

            const element = createElement('c-ure-routing-simulator', { is: UreRoutingSimulator });
            document.body.appendChild(element);

            await new Promise(resolve => setTimeout(resolve, 0));

            element.isSimulating = true;
            expect(element.isSimulateDisabled).toBe(true);

            document.body.removeChild(element);
        });

        it('resultIcon is success when simulation succeeds', async () => {
            getActiveConfigs.mockResolvedValue([]);

            const element = createElement('c-ure-routing-simulator', { is: UreRoutingSimulator });
            document.body.appendChild(element);

            await new Promise(resolve => setTimeout(resolve, 0));

            element.simulateResult = { success: true };
            expect(element.resultIcon).toBe('utility:success');
            expect(element.resultVariant).toBe('success');

            document.body.removeChild(element);
        });

        it('resultIcon is warning when simulation fails', async () => {
            getActiveConfigs.mockResolvedValue([]);

            const element = createElement('c-ure-routing-simulator', { is: UreRoutingSimulator });
            document.body.appendChild(element);

            await new Promise(resolve => setTimeout(resolve, 0));

            element.simulateResult = { success: false };
            expect(element.resultIcon).toBe('utility:warning');
            expect(element.resultVariant).toBe('warning');

            document.body.removeChild(element);
        });

    });

});
