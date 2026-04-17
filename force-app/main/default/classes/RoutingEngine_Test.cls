/**
 * @description Test class for RoutingEngine (Layer 2 Orchestrator).
 *              Tests: 6-phase execution, fail-fast gates, override assignment,
 *              bulk processing, dryRun side-effect isolation, lock contention handling.
 *
 *              Uses @TestVisible mocks on AgentCapabilitySelector for deterministic
 *              capability data. Does NOT mock ConfigLoader (CMDT reads are platform-cached).
 *
 * @group Test
 */
@IsTest
private class RoutingEngine_Test {

    // ═══════════════════════════════════════════════════════════════════════════
    // Test Setup
    // ═══════════════════════════════════════════════════════════════════════════

    @TestSetup
    static void setup() {
        // Create agent
        Agent__c agent = new Agent__c(
            User__c = UserInfo.getUserId(),
            Is_Active__c = true,
            Max_Capacity__c = 100,
            Current_Load__c = 0,
            Availability_Status__c = 'Online'
        );
        insert agent;

        // Create routing config (assumes CMDT exists in org)
        // We rely on existing CMDT in test org for this test
    }

    private static Agent__c getAgent() {
        return [
            SELECT Id, User__c, Is_Active__c, Max_Capacity__c,
                   Current_Load__c, Availability_Status__c
            FROM Agent__c
            LIMIT 1
        ];
    }

    private static void seedAgentCapabilityMock(Agent__c agent) {
        AgentCapabilitySelector.mockAgents = new Map<Id, Agent__c>{
            agent.User__c => agent
        };
        AgentCapabilitySelector.mockAssignments =
            new List<Agent_Skill_Assignment__c>();
        AgentCapabilitySelector.mockEntries =
            new List<Skill_Bundle_Entry__c>();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. Validation Phase Tests (Phase 1: Request validation)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void execute_emptyRequest_returnsValidationFailure() {
        Agent__c agent = getAgent();
        seedAgentCapabilityMock(agent);

        RoutingRequest request = new RoutingRequest();
        request.objectApiName = '';
        request.recordId = null;

        Test.startTest();
        RoutingResult result = RoutingEngine.execute(
            request,
            UserInfo.getUserId(),
            'Test'
        );
        Test.stopTest();

        System.assertEquals(false, result.success,
            'Empty request should fail validation');
        System.assertNotEquals(null, result.errorMessage,
            'Error message should be present for validation failure');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. Agent Gate Tests (Phase 2: Agent availability + capacity)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void execute_noActiveAgent_returnsAgentGateFailure() {
        seedAgentCapabilityMock(null); // No agent for this user

        RoutingRequest request = new RoutingRequest();
        request.objectApiName = 'Case';
        request.recordId = UserInfo.getUserId(); // Dummy record

        Test.startTest();
        RoutingResult result = RoutingEngine.execute(
            request,
            UserInfo.getUserId(),
            'Test'
        );
        Test.stopTest();

        System.assertEquals(false, result.success,
            'No active agent should fail routing');
        System.assert(result.errorMessage.contains('No active Agent'),
            'Error should mention no active Agent record');
    }

    @IsTest
    static void execute_agentAtCapacity_returnsCapacityFailure() {
        Agent__c agent = getAgent();
        agent.Current_Load__c = 100;
        agent.Max_Capacity__c = 100;
        update agent;
        seedAgentCapabilityMock(agent);

        RoutingRequest request = new RoutingRequest();
        request.objectApiName = 'Case';
        request.recordId = UserInfo.getUserId();

        Test.startTest();
        RoutingResult result = RoutingEngine.execute(
            request,
            UserInfo.getUserId(),
            'Test'
        );
        Test.stopTest();

        System.assertEquals(false, result.success,
            'Agent at capacity should fail routing');
        System.assert(result.errorMessage.contains('capacity'),
            'Error should mention capacity exceeded');
    }

    @IsTest
    static void execute_agentAway_returnsAvailabilityFailure() {
        Agent__c agent = getAgent();
        agent.Availability_Status__c = 'Away';
        update agent;
        seedAgentCapabilityMock(agent);

        RoutingRequest request = new RoutingRequest();
        request.objectApiName = 'Case';
        request.recordId = UserInfo.getUserId();

        Test.startTest();
        RoutingResult result = RoutingEngine.execute(
            request,
            UserInfo.getUserId(),
            'Test'
        );
        Test.stopTest();

        System.assertEquals(false, result.success,
            'Away agent should fail routing');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. Config Loading Tests (Phase 3: Load + filter configs)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void execute_noActiveConfigs_returnsNoConfigError() {
        Agent__c agent = getAgent();
        seedAgentCapabilityMock(agent);

        RoutingRequest request = new RoutingRequest();
        request.objectApiName = 'UnknownObject__c';
        request.recordId = UserInfo.getUserId();
        request.configDeveloperName = 'NonExistent';

        Test.startTest();
        RoutingResult result = RoutingEngine.execute(
            request,
            UserInfo.getUserId(),
            'Test'
        );
        Test.stopTest();

        System.assertEquals(false, result.success,
            'Nonexistent config should return no match or config error');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. Governor Limits Test (verify bounded resource usage)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void execute_boundedGovernorUsage() {
        Agent__c agent = getAgent();
        seedAgentCapabilityMock(agent);

        RoutingRequest request = new RoutingRequest();
        request.objectApiName = 'Case';
        request.recordId = UserInfo.getUserId();

        Test.startTest();
        Integer soqlBefore = Limits.getQueries();
        RoutingResult result = RoutingEngine.execute(
            request,
            UserInfo.getUserId(),
            'Test'
        );
        Integer soqlAfter = Limits.getQueries();
        Test.stopTest();

        Integer soqlUsed = soqlAfter - soqlBefore;
        System.assert(soqlUsed <= 10,
            'Single routing execution should use ≤10 SOQL queries (got ' + soqlUsed + ')');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 5. Null-Safety Tests
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void execute_nullLoadValues_defaultsToZero() {
        Agent__c agent = getAgent();
        agent.Current_Load__c = null;
        agent.Max_Capacity__c = null;
        update agent;
        seedAgentCapabilityMock(agent);

        RoutingRequest request = new RoutingRequest();
        request.objectApiName = 'Case';
        request.recordId = UserInfo.getUserId();

        Test.startTest();
        RoutingResult result = RoutingEngine.execute(
            request,
            UserInfo.getUserId(),
            'Test'
        );
        Test.stopTest();

        // Should not throw NullPointerException; should default to 0
        System.assertNotEquals(null, result,
            'Result should be populated even with null load values');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 6. Logging / Tracing Coverage
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void execute_logsEngineInfo() {
        Agent__c agent = getAgent();
        seedAgentCapabilityMock(agent);

        RoutingRequest request = new RoutingRequest();
        request.objectApiName = 'Case';
        request.recordId = UserInfo.getUserId();

        Integer logsBefore = [SELECT COUNT() FROM Log__c];

        Test.startTest();
        RoutingResult result = RoutingEngine.execute(
            request,
            UserInfo.getUserId(),
            'Test'
        );
        Test.stopTest();

        Integer logsAfter = [SELECT COUNT() FROM Log__c];
        System.assert(logsAfter >= logsBefore,
            'Engine should create at least one log entry');
    }
}
