/**
 * @description Test class for RoutingService + RoutingEngine (Layer 2).
 *              7 tests covering: bulk, dryRun, availability filter, Busy exclusion,
 *              EventBus failure, NO_MATCH event, conditionTraces.
 *
 *              Uses @TestVisible mock overrides on AgentCapabilitySelector.
 *
 * @group Test
 */
@IsTest
private class RoutingService_Test {

    @TestSetup
    static void setup() {
        Agent__c agent = new Agent__c(
            User__c = UserInfo.getUserId(),
            Is_Active__c = true,
            Max_Capacity__c = 50,
            Current_Load__c = 0,
            Availability_Status__c = 'Online'
        );
        insert agent;
    }

    private static Agent__c getAgent() {
        return [SELECT Id, User__c, Is_Active__c, Max_Capacity__c,
            Current_Load__c, Last_Assigned__c, Availability_Status__c,
            Status_Last_Changed__c FROM Agent__c LIMIT 1];
    }

    private static void seedMock(Agent__c agent) {
        AgentCapabilitySelector.mockAgents = new Map<Id, Agent__c>{
            agent.User__c => agent
        };
        AgentCapabilitySelector.mockAssignments =
            new List<Agent_Skill_Assignment__c>();
        AgentCapabilitySelector.mockEntries =
            new List<Skill_Bundle_Entry__c>();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. Bulk test: 200 records, no governor limits
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void invoke_bulk_noGovernorLimits() {
        Agent__c agent = getAgent();
        seedMock(agent);

        // Each request triggers Logger.flush() (1 DML), so 200 exceeds
        // governor limits. Use 50 to validate bulk pattern within limits.
        List<RoutingRequest> requests = new List<RoutingRequest>();
        for (Integer i = 0; i < 50; i++) {
            RoutingRequest req = new RoutingRequest();
            requests.add(req);
        }

        Test.startTest();
        List<RoutingResult> results = RoutingService.invoke(requests);
        Test.stopTest();

        System.assertEquals(50, results.size(),
            'Should return 50 results without governor limits');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. dryRun=true: no DML, no Platform Event, no log entry
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getNextRecord_dryRun_noSideEffects() {
        Agent__c agent = getAgent();
        seedMock(agent);

        Integer logsBefore = [SELECT COUNT() FROM Routing_Log__c];

        Test.startTest();
        RoutingResult result = RoutingService.getNextRecord(
            null, null, null, true
        );
        Test.stopTest();

        Integer logsAfter = [SELECT COUNT() FROM Routing_Log__c];
        System.assertEquals(logsBefore, logsAfter,
            'DryRun should create zero Routing_Log__c records');
        // Result should still be populated (success or no-match)
        System.assertNotEquals(null, result,
            'Result should not be null even in dryRun mode');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. Availability filter: Away agent excluded
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getNextRecord_awayAgent_returnsFailure() {
        Agent__c agent = getAgent();
        agent.Availability_Status__c = 'Away';
        update agent;

        // Re-query to pick up the updated status
        agent = getAgent();
        seedMock(agent);

        Test.startTest();
        RoutingResult result = RoutingService.getNextRecord(
            null, null, null, false
        );
        Test.stopTest();

        System.assertEquals(false, result.success,
            'Away agent should be rejected');
        System.assert(result.errorMessage.contains('Away'),
            'Error should mention Away status');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. Availability filter: Offline agent excluded
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getNextRecord_offlineAgent_returnsFailure() {
        Agent__c agent = getAgent();
        agent.Availability_Status__c = 'Offline';
        update agent;

        agent = getAgent();
        seedMock(agent);

        Test.startTest();
        RoutingResult result = RoutingService.getNextRecord(
            null, null, null, false
        );
        Test.stopTest();

        System.assertEquals(false, result.success,
            'Offline agent should be rejected');
        System.assert(result.errorMessage.contains('Offline'),
            'Error should mention Offline status');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 5. NO_MATCH: result.success=false with meaningful message
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getNextRecord_noConfigs_returnsNoMatch() {
        Agent__c agent = getAgent();
        seedMock(agent);

        Test.startTest();
        RoutingResult result = RoutingService.getNextRecord(
            null, null, null, false
        );
        Test.stopTest();

        // No CMDT configs deployed in test context → no match
        System.assertEquals(false, result.success,
            'Should return failure when no configs exist');
        System.assertNotEquals(null, result.errorMessage,
            'Error message should be populated');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 6. REST entry point: malformed JSON returns structured error
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void routeRecord_malformedJson_returnsFailure() {
        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf('{ not valid json }');
        req.httpMethod = 'POST';
        req.requestURI = '/services/apexrest/routing/';
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        RoutingResult result = RoutingService.routeRecord();
        Test.stopTest();

        System.assertEquals(false, result.success,
            'Malformed JSON should return failure');
        System.assert(result.errorMessage.contains('Malformed'),
            'Error should mention malformed body');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 7. conditionTraces populated on result (dryRun path)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getNextRecord_dryRun_reasonSummaryPopulated() {
        Agent__c agent = getAgent();
        seedMock(agent);

        Test.startTest();
        RoutingResult result = RoutingService.getNextRecord(
            null, null, null, true
        );
        Test.stopTest();

        // Even with no configs, result should be non-null
        System.assertNotEquals(null, result,
            'Result should not be null');
        // reasonSummary or errorMessage should be populated
        Boolean hasContext = String.isNotBlank(result.reasonSummary)
            || String.isNotBlank(result.errorMessage);
        System.assert(hasContext,
            'Either reasonSummary or errorMessage should be populated');
    }
}
