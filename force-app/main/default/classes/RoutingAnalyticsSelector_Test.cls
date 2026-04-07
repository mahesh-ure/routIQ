/**
 * @description Tests for RoutingAnalyticsSelector — validates aggregate query
 *              correctness using inserted Routing_Log__c records.
 *
 *              Uses @TestSetup for shared test data. Each test method validates
 *              one lens query with positive and boundary cases.
 *
 *              Bulk: inserts 10 log records across 3 days to validate GROUP BY
 *              aggregation and multi-day trending.
 *
 * @group Test
 */
@IsTest
private class RoutingAnalyticsSelector_Test {

    @TestSetup
    static void setupData() {
        // Create test user + agent for Assigned_To__c
        List<Routing_Log__c> logs = new List<Routing_Log__c>();
        DateTime now = System.now();

        // ─── Success records with SLA data (3 days) ──────────────────
        for (Integer i = 0; i < 6; i++) {
            logs.add(new Routing_Log__c(
                Status__c = 'Success',
                Config_Developer_Name__c = (Math.mod(i, 2) == 0) ? 'Case_Routing' : 'Lead_Routing',
                Object_API_Name__c = (Math.mod(i, 2) == 0) ? 'Case' : 'Lead',
                Record_Id__c = '001000000000' + String.valueOf(i).leftPad(6, '0'),
                Routed_At__c = now.addDays(-Math.mod(i, 3)),
                Assignment_Duration_Ms__c = 500 + (i * 100),
                SLA_Met__c = (Math.mod(i, 3) == 0) ? 'Breached' : 'Met',
                Agent_Name__c = (Math.mod(i, 2) == 0) ? 'Agent Alpha' : 'Agent Beta',
                Entry_Point__c = 'LWC'
            ));
        }

        // ─── Failed records (no SLA, no duration) ────────────────────
        for (Integer i = 0; i < 3; i++) {
            logs.add(new Routing_Log__c(
                Status__c = 'Failed',
                Config_Developer_Name__c = 'Case_Routing',
                Object_API_Name__c = 'Case',
                Record_Id__c = '001000000001' + String.valueOf(i).leftPad(6, '0'),
                Routed_At__c = now.addDays(-1),
                Entry_Point__c = 'REST'
            ));
        }

        // ─── Success record WITHOUT SLA (SLA not configured) ─────────
        logs.add(new Routing_Log__c(
            Status__c = 'Success',
            Config_Developer_Name__c = 'Task_Routing',
            Object_API_Name__c = 'Task',
            Record_Id__c = '001000000002000000',
            Routed_At__c = now,
            Assignment_Duration_Ms__c = 200,
            Agent_Name__c = 'Agent Gamma',
            Entry_Point__c = 'InvocableMethod'
        ));

        insert logs;
    }

    // ═══════════════════════════════════════════════════════════════════
    // Lens 1: Routing Velocity
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void testGetRoutingVelocity_returnsGroupedData() {
        Test.startTest();
        List<AggregateResult> results =
            RoutingAnalyticsSelector.getRoutingVelocity(30);
        Test.stopTest();

        // Should return multiple days (success records with duration across 3 days + 1 today)
        System.assert(!results.isEmpty(), 'Should return velocity data');

        // Validate aggregate structure
        for (AggregateResult ar : results) {
            System.assertNotEquals(null, ar.get('routedDay'), 'routedDay should be populated');
            System.assertNotEquals(null, ar.get('avgDurationMs'), 'avgDurationMs should be populated');
            System.assert((Integer) ar.get('routingCount') > 0, 'routingCount should be > 0');
        }
    }

    @IsTest
    static void testGetRoutingVelocity_defaultDays() {
        Test.startTest();
        // Null days should default to 30
        List<AggregateResult> results =
            RoutingAnalyticsSelector.getRoutingVelocity(null);
        Test.stopTest();

        System.assert(!results.isEmpty(), 'Should return data with null days (defaults to 30)');
    }

    @IsTest
    static void testGetRoutingVelocity_zeroDays() {
        Test.startTest();
        List<AggregateResult> results =
            RoutingAnalyticsSelector.getRoutingVelocity(0);
        Test.stopTest();

        // Zero should default to 30
        System.assert(!results.isEmpty(), 'Should return data with zero days (defaults to 30)');
    }

    // ═══════════════════════════════════════════════════════════════════
    // Lens 2: SLA Compliance
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void testGetSlaComplianceByConfig_returnsGroupedData() {
        Test.startTest();
        List<AggregateResult> results =
            RoutingAnalyticsSelector.getSlaComplianceByConfig(30);
        Test.stopTest();

        System.assert(!results.isEmpty(), 'Should return SLA config data');

        // Should have entries for Case_Routing and Lead_Routing
        Set<String> configs = new Set<String>();
        for (AggregateResult ar : results) {
            configs.add((String) ar.get('configName'));
        }
        System.assert(configs.contains('Case_Routing'), 'Should include Case_Routing');
        System.assert(configs.contains('Lead_Routing'), 'Should include Lead_Routing');
    }

    @IsTest
    static void testGetSlaComplianceByAgent_returnsGroupedData() {
        Test.startTest();
        List<AggregateResult> results =
            RoutingAnalyticsSelector.getSlaComplianceByAgent(30);
        Test.stopTest();

        System.assert(!results.isEmpty(), 'Should return SLA agent data');

        Set<String> agents = new Set<String>();
        for (AggregateResult ar : results) {
            agents.add((String) ar.get('agentName'));
        }
        System.assert(agents.contains('Agent Alpha'), 'Should include Agent Alpha');
        System.assert(agents.contains('Agent Beta'), 'Should include Agent Beta');
        // Agent Gamma has no SLA data — should NOT appear
        System.assert(!agents.contains('Agent Gamma'), 'Agent Gamma has no SLA — excluded');
    }

    // ═══════════════════════════════════════════════════════════════════
    // Lens 3: Agent Utilisation
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void testGetAgentUtilisation_returnsGroupedData() {
        Test.startTest();
        List<AggregateResult> results =
            RoutingAnalyticsSelector.getAgentUtilisation(30);
        Test.stopTest();

        System.assert(!results.isEmpty(), 'Should return utilisation data');

        Set<String> agents = new Set<String>();
        for (AggregateResult ar : results) {
            agents.add((String) ar.get('agentName'));
            System.assert((Integer) ar.get('assignedCount') > 0, 'assignedCount should be > 0');
        }
        System.assert(agents.contains('Agent Alpha'), 'Should include Agent Alpha');
        System.assert(agents.contains('Agent Beta'), 'Should include Agent Beta');
        System.assert(agents.contains('Agent Gamma'), 'Should include Agent Gamma');
    }
}
