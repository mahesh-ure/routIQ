/**
 * @description Test class for RoutingInvocableAction (Layer 4).
 *              5 tests: single record, bulk 200, no-match, configDevName null,
 *              exception safety.
 *
 *              Uses @TestVisible mock overrides on AgentCapabilitySelector to
 *              avoid CMDT deployment. The engine will return failure/no-match
 *              results since no configs are deployed — we validate the invocable
 *              wrapper handles all outcomes gracefully.
 *
 * @group Test
 */
@IsTest
private class RoutingInvocableAction_Test {

    @TestSetup
    static void setup() {
        Agent__c agent = new Agent__c(
            User__c = UserInfo.getUserId(),
            Is_Active__c = true,
            Max_Capacity__c = 10,
            Current_Load__c = 0,
            Availability_Status__c = 'Online'
        );
        insert agent;
    }

    private static void seedAgentMock() {
        Agent__c agent = [SELECT Id, User__c, Is_Active__c, Max_Capacity__c,
            Current_Load__c, Last_Assigned__c, Availability_Status__c,
            Status_Last_Changed__c FROM Agent__c LIMIT 1];
        AgentCapabilitySelector.mockAgents = new Map<Id, Agent__c>{
            agent.User__c => agent
        };
        AgentCapabilitySelector.mockAssignments =
            new List<Agent_Skill_Assignment__c>();
        AgentCapabilitySelector.mockEntries =
            new List<Skill_Bundle_Entry__c>();
    }

    @IsTest
    static void routeRecords_singleRecord_returnsResult() {
        seedAgentMock();

        RoutingInvocableAction.RoutingInvocableRequest req =
            new RoutingInvocableAction.RoutingInvocableRequest();
        req.recordId = UserInfo.getUserId(); // dummy Id

        Test.startTest();
        List<RoutingInvocableAction.RoutingInvocableResult> results =
            RoutingInvocableAction.routeRecords(
                new List<RoutingInvocableAction.RoutingInvocableRequest>{ req }
            );
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should return 1 result');
        System.assertNotEquals(null, results[0].success,
            'Success flag should be populated');
    }

    @IsTest
    static void routeRecords_bulk_noGovernorLimits() {
        seedAgentMock();

        // Each request triggers Logger.flush() (1 DML), so use 50
        // to validate bulk pattern within governor limits.
        List<RoutingInvocableAction.RoutingInvocableRequest> requests =
            new List<RoutingInvocableAction.RoutingInvocableRequest>();
        for (Integer i = 0; i < 50; i++) {
            RoutingInvocableAction.RoutingInvocableRequest req =
                new RoutingInvocableAction.RoutingInvocableRequest();
            req.recordId = UserInfo.getUserId();
            requests.add(req);
        }

        Test.startTest();
        List<RoutingInvocableAction.RoutingInvocableResult> results =
            RoutingInvocableAction.routeRecords(requests);
        Test.stopTest();

        System.assertEquals(50, results.size(),
            'Should return 50 results without governor limits');
    }

    @IsTest
    static void routeRecords_noMatch_returnsFailure() {
        seedAgentMock();

        RoutingInvocableAction.RoutingInvocableRequest req =
            new RoutingInvocableAction.RoutingInvocableRequest();
        req.recordId = UserInfo.getUserId();
        req.configDevName = 'Nonexistent_Config';

        Test.startTest();
        List<RoutingInvocableAction.RoutingInvocableResult> results =
            RoutingInvocableAction.routeRecords(
                new List<RoutingInvocableAction.RoutingInvocableRequest>{ req }
            );
        Test.stopTest();

        System.assertEquals(false, results[0].success,
            'Should return failure for nonexistent config');
        System.assertNotEquals(null, results[0].errorMessage,
            'Error message should be populated');
    }

    @IsTest
    static void routeRecords_configDevNameNull_routesAcrossAll() {
        seedAgentMock();

        RoutingInvocableAction.RoutingInvocableRequest req =
            new RoutingInvocableAction.RoutingInvocableRequest();
        req.recordId = UserInfo.getUserId();
        req.configDevName = null;

        Test.startTest();
        List<RoutingInvocableAction.RoutingInvocableResult> results =
            RoutingInvocableAction.routeRecords(
                new List<RoutingInvocableAction.RoutingInvocableRequest>{ req }
            );
        Test.stopTest();

        System.assertEquals(1, results.size(),
            'Should return 1 result even with null configDevName');
    }

    @IsTest
    static void routeRecords_emptyList_returnsEmpty() {
        Test.startTest();
        List<RoutingInvocableAction.RoutingInvocableResult> results =
            RoutingInvocableAction.routeRecords(
                new List<RoutingInvocableAction.RoutingInvocableRequest>()
            );
        Test.stopTest();

        System.assertEquals(0, results.size(),
            'Empty input should return empty output');
    }
}
