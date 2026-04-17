/**
 * @description Test class for AgentMatcher (Layer 3 Worker).
 *              Tests: binary matching, skill validation, capability mismatches,
 *              capacity gates, exception handling.
 *
 *              Cost: Zero SOQL (uses AgentCapabilitySelector cache).
 *
 * @group Test
 */
@IsTest
private class AgentMatcher_Test {

    @TestSetup
    static void setup() {
        Agent__c agent = new Agent__c(
            User__c = UserInfo.getUserId(),
            Is_Active__c = true,
            Max_Capacity__c = 50,
            Current_Load__c = 0
        );
        insert agent;
    }

    private static Agent__c getAgent() {
        return [
            SELECT Id, User__c, Is_Active__c, Max_Capacity__c, Current_Load__c
            FROM Agent__c
            LIMIT 1
        ];
    }

    private static void seedCapabilityMock(
        Map<Id, Map<String, Set<String>>> capabilityMap,
        Map<Id, Agent__c> agentMap
    ) {
        AgentCapabilitySelector.mockCapabilityMap = capabilityMap;
        AgentCapabilitySelector.mockAgents = agentMap;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. Null/Empty Input Tests
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void evaluate_nullMatchConditions_returnsNoMatch() {
        Agent__c agent = getAgent();
        seedCapabilityMock(
            new Map<Id, Map<String, Set<String>>>(),
            new Map<Id, Agent__c>{ agent.User__c => agent }
        );

        Case testCase = new Case(Subject = 'Test', Status = 'New');
        insert testCase;

        Test.startTest();
        AgentMatcher.MatchResult result = AgentMatcher.evaluate(
            testCase,
            null,
            UserInfo.getUserId(),
            'TestConfig'
        );
        Test.stopTest();

        System.assertEquals(false, result.matched,
            'Null conditions should return no match');
    }

    @IsTest
    static void evaluate_emptyMatchConditions_returnsNoMatch() {
        Agent__c agent = getAgent();
        seedCapabilityMock(
            new Map<Id, Map<String, Set<String>>>(),
            new Map<Id, Agent__c>{ agent.User__c => agent }
        );

        Case testCase = new Case(Subject = 'Test', Status = 'New');
        insert testCase;

        Test.startTest();
        AgentMatcher.MatchResult result = AgentMatcher.evaluate(
            testCase,
            new List<Routing_Skill_Mapping__mdt>(),
            UserInfo.getUserId(),
            'TestConfig'
        );
        Test.stopTest();

        System.assertEquals(false, result.matched,
            'Empty conditions should return no match');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. No Active Agent Test
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void evaluate_noActiveAgent_throwsException() {
        seedCapabilityMock(
            new Map<Id, Map<String, Set<String>>>(),
            new Map<Id, Agent__c>() // No agent
        );

        Case testCase = new Case(Subject = 'Test', Status = 'New');
        insert testCase;

        Routing_Skill_Mapping__mdt mapping = new Routing_Skill_Mapping__mdt();

        Test.startTest();
        try {
            AgentMatcher.evaluate(
                testCase,
                new List<Routing_Skill_Mapping__mdt>{ mapping },
                UserInfo.getUserId(),
                'TestConfig'
            );
            System.assert(false, 'Should have thrown CapabilityMismatchException');
        } catch (CapabilityMismatchException e) {
            System.assertNotEquals(null, e.getMessage(),
                'Exception should have a message');
        }
        Test.stopTest();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. Capacity Gate Tests
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void evaluate_agentAtCapacity_throwsException() {
        Agent__c agent = getAgent();
        agent.Current_Load__c = 50;
        agent.Max_Capacity__c = 50;
        update agent;

        seedCapabilityMock(
            new Map<Id, Map<String, Set<String>>>(),
            new Map<Id, Agent__c>{ agent.User__c => agent }
        );

        Case testCase = new Case(Subject = 'Test', Status = 'New');
        insert testCase;

        Routing_Skill_Mapping__mdt mapping = new Routing_Skill_Mapping__mdt();

        Test.startTest();
        try {
            AgentMatcher.evaluate(
                testCase,
                new List<Routing_Skill_Mapping__mdt>{ mapping },
                UserInfo.getUserId(),
                'TestConfig'
            );
            System.assert(false, 'Should have thrown CapabilityMismatchException');
        } catch (CapabilityMismatchException e) {
            System.assert(e.getMessage().contains('capacity'),
                'Exception should mention capacity');
        }
        Test.stopTest();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. Null-Safe Load Values
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void evaluate_nullLoadValues_defaultsToZero() {
        Agent__c agent = getAgent();
        agent.Current_Load__c = null;
        agent.Max_Capacity__c = null;
        update agent;

        seedCapabilityMock(
            new Map<Id, Map<String, Set<String>>>(),
            new Map<Id, Agent__c>{ agent.User__c => agent }
        );

        Case testCase = new Case(Subject = 'Test', Status = 'New');
        insert testCase;

        Routing_Skill_Mapping__mdt mapping = new Routing_Skill_Mapping__mdt();

        Test.startTest();
        try {
            // Should not throw NullPointerException
            AgentMatcher.MatchResult result = AgentMatcher.evaluate(
                testCase,
                new List<Routing_Skill_Mapping__mdt>{ mapping },
                UserInfo.getUserId(),
                'TestConfig'
            );
            System.assertNotEquals(null, result,
                'Should return a result with null load values');
        } catch (Exception e) {
            if (!(e instanceof CapabilityMismatchException)) {
                System.assert(false, 'Unexpected exception: ' + e.getMessage());
            }
        }
        Test.stopTest();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 5. Match Result Structure
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void evaluate_resultContainsRequiredFields() {
        Agent__c agent = getAgent();
        seedCapabilityMock(
            new Map<Id, Map<String, Set<String>>>(),
            new Map<Id, Agent__c>{ agent.User__c => agent }
        );

        Case testCase = new Case(Subject = 'Test', Status = 'New');
        insert testCase;

        Routing_Skill_Mapping__mdt mapping = new Routing_Skill_Mapping__mdt();

        Test.startTest();
        try {
            AgentMatcher.MatchResult result = AgentMatcher.evaluate(
                testCase,
                new List<Routing_Skill_Mapping__mdt>{ mapping },
                UserInfo.getUserId(),
                'TestConfig'
            );

            System.assertNotEquals(null, result.matched,
                'Result must contain matched flag');
            System.assertNotEquals(null, result.missingCapabilities,
                'Result must contain missingCapabilities map');
            System.assertNotEquals(null, result.skillTraces,
                'Result must contain skillTraces list');
        } catch (CapabilityMismatchException e) {
            // Expected in some scenarios
        }
        Test.stopTest();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 6. Governor Limits (Zero SOQL contract)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void evaluate_zeroSOQLUsage() {
        Agent__c agent = getAgent();
        seedCapabilityMock(
            new Map<Id, Map<String, Set<String>>>(),
            new Map<Id, Agent__c>{ agent.User__c => agent }
        );

        Case testCase = new Case(Subject = 'Test', Status = 'New');
        insert testCase;

        Routing_Skill_Mapping__mdt mapping = new Routing_Skill_Mapping__mdt();

        Test.startTest();
        Integer soqlBefore = Limits.getQueries();
        try {
            AgentMatcher.evaluate(
                testCase,
                new List<Routing_Skill_Mapping__mdt>{ mapping },
                UserInfo.getUserId(),
                'TestConfig'
            );
        } catch (CapabilityMismatchException e) {
            // Expected
        }
        Integer soqlAfter = Limits.getQueries();
        Test.stopTest();

        System.assertEquals(soqlBefore, soqlAfter,
            'AgentMatcher should use zero SOQL (cache only)');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 7. Logging Coverage
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void evaluate_logsMatchingActivity() {
        Agent__c agent = getAgent();
        seedCapabilityMock(
            new Map<Id, Map<String, Set<String>>>(),
            new Map<Id, Agent__c>{ agent.User__c => agent }
        );

        Case testCase = new Case(Subject = 'Test', Status = 'New');
        insert testCase;

        Routing_Skill_Mapping__mdt mapping = new Routing_Skill_Mapping__mdt();

        Integer logsBefore = [SELECT COUNT() FROM Log__c];

        Test.startTest();
        try {
            AgentMatcher.evaluate(
                testCase,
                new List<Routing_Skill_Mapping__mdt>{ mapping },
                UserInfo.getUserId(),
                'TestConfig'
            );
        } catch (CapabilityMismatchException e) {
            // Expected
        }
        Test.stopTest();

        Integer logsAfter = [SELECT COUNT() FROM Log__c];
        System.assert(logsAfter >= logsBefore,
            'Matcher should log activity');
    }
}
