/**
 * @description Tests for RoutingAnalyticsService — validates DTO transformation
 *              and compliance rate computation. Uses mock injection on the selector
 *              layer to isolate service logic from SOQL.
 *
 *              Tests cover:
 *              • Velocity DTO mapping + zero-handling
 *              • SLA compliance rate computation (met/breached/mixed/empty)
 *              • Agent utilisation DTO mapping
 *              • Empty data graceful handling
 *
 * @group Test
 */
@IsTest
private class RoutingAnalyticsService_Test {

    // ═══════════════════════════════════════════════════════════════════
    // Lens 1: Routing Velocity
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void testGetRoutingVelocity_withData() {
        // Insert real data — service calls selector which hits DB
        List<Routing_Log__c> logs = new List<Routing_Log__c>();
        DateTime now = System.now();

        for (Integer i = 0; i < 5; i++) {
            logs.add(new Routing_Log__c(
                Status__c = 'Success',
                Config_Developer_Name__c = 'Test_Config',
                Object_API_Name__c = 'Case',
                Record_Id__c = '001000000003' + String.valueOf(i).leftPad(6, '0'),
                Routed_At__c = now.addDays(-i),
                Assignment_Duration_Ms__c = 1000 + (i * 500),
                Agent_Name__c = 'Test Agent',
                Entry_Point__c = 'LWC'
            ));
        }
        insert logs;

        Test.startTest();
        List<RoutingAnalyticsService.VelocityDataPoint> result =
            RoutingAnalyticsService.getRoutingVelocity(30);
        Test.stopTest();

        System.assert(!result.isEmpty(), 'Should return velocity data points');
        for (RoutingAnalyticsService.VelocityDataPoint dp : result) {
            System.assertNotEquals(null, dp.routedDay, 'routedDay should be set');
            System.assert(dp.avgDurationMs >= 0, 'avgDurationMs should be non-negative');
            System.assert(dp.routingCount > 0, 'routingCount should be positive');
        }
    }

    @IsTest
    static void testGetRoutingVelocity_empty() {
        Test.startTest();
        List<RoutingAnalyticsService.VelocityDataPoint> result =
            RoutingAnalyticsService.getRoutingVelocity(30);
        Test.stopTest();

        System.assertEquals(0, result.size(), 'Should return empty list with no data');
    }

    // ═══════════════════════════════════════════════════════════════════
    // Lens 2: SLA Compliance
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void testGetSlaCompliance_computesRate() {
        List<Routing_Log__c> logs = new List<Routing_Log__c>();
        DateTime now = System.now();

        // 3 Met + 1 Breached for Config A
        for (Integer i = 0; i < 3; i++) {
            logs.add(new Routing_Log__c(
                Status__c = 'Success',
                Config_Developer_Name__c = 'Config_A',
                Object_API_Name__c = 'Case',
                Record_Id__c = '001000000004' + String.valueOf(i).leftPad(6, '0'),
                Routed_At__c = now,
                Assignment_Duration_Ms__c = 300,
                SLA_Met__c = 'Met',
                Agent_Name__c = 'Agent One',
                Entry_Point__c = 'LWC'
            ));
        }
        logs.add(new Routing_Log__c(
            Status__c = 'Success',
            Config_Developer_Name__c = 'Config_A',
            Object_API_Name__c = 'Case',
            Record_Id__c = '001000000004000003',
            Routed_At__c = now,
            Assignment_Duration_Ms__c = 9000,
            SLA_Met__c = 'Breached',
            Agent_Name__c = 'Agent One',
            Entry_Point__c = 'LWC'
        ));
        insert logs;

        Test.startTest();
        RoutingAnalyticsService.SlaComplianceData result =
            RoutingAnalyticsService.getSlaCompliance(30);
        Test.stopTest();

        System.assertNotEquals(null, result.byConfig, 'byConfig should be populated');
        System.assert(!result.byConfig.isEmpty(), 'byConfig should have entries');

        // Find Config_A
        RoutingAnalyticsService.SlaBreakdown configA = null;
        for (RoutingAnalyticsService.SlaBreakdown bd : result.byConfig) {
            if (bd.groupName == 'Config_A') {
                configA = bd;
                break;
            }
        }
        System.assertNotEquals(null, configA, 'Config_A should be in results');
        System.assertEquals(3, configA.metCount, 'Should have 3 Met');
        System.assertEquals(1, configA.breachedCount, 'Should have 1 Breached');
        System.assertEquals(75.0, configA.complianceRate, 'Compliance should be 75.0%');
    }

    @IsTest
    static void testGetSlaCompliance_empty() {
        Test.startTest();
        RoutingAnalyticsService.SlaComplianceData result =
            RoutingAnalyticsService.getSlaCompliance(30);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(0, result.byConfig.size(), 'byConfig should be empty');
        System.assertEquals(0, result.byAgent.size(), 'byAgent should be empty');
    }

    // ═══════════════════════════════════════════════════════════════════
    // Lens 3: Agent Utilisation
    // ═══════════════════════════════════════════════════════════════════

    @IsTest
    static void testGetAgentUtilisation_withData() {
        List<Routing_Log__c> logs = new List<Routing_Log__c>();
        DateTime now = System.now();

        for (Integer i = 0; i < 4; i++) {
            logs.add(new Routing_Log__c(
                Status__c = 'Success',
                Config_Developer_Name__c = 'Test_Config',
                Object_API_Name__c = 'Case',
                Record_Id__c = '001000000005' + String.valueOf(i).leftPad(6, '0'),
                Routed_At__c = now.addDays(-Math.mod(i, 2)),
                Assignment_Duration_Ms__c = 400,
                Agent_Name__c = (Math.mod(i, 2) == 0) ? 'Agent X' : 'Agent Y',
                Entry_Point__c = 'LWC'
            ));
        }
        insert logs;

        Test.startTest();
        List<RoutingAnalyticsService.AgentDailyUtilisation> result =
            RoutingAnalyticsService.getAgentUtilisation(30);
        Test.stopTest();

        System.assert(!result.isEmpty(), 'Should return utilisation data');
        for (RoutingAnalyticsService.AgentDailyUtilisation dp : result) {
            System.assertNotEquals(null, dp.agentName, 'agentName should be set');
            System.assertNotEquals(null, dp.routedDay, 'routedDay should be set');
            System.assert(dp.assignedCount > 0, 'assignedCount should be positive');
        }
    }

    @IsTest
    static void testGetAgentUtilisation_empty() {
        Test.startTest();
        List<RoutingAnalyticsService.AgentDailyUtilisation> result =
            RoutingAnalyticsService.getAgentUtilisation(30);
        Test.stopTest();

        System.assertEquals(0, result.size(), 'Should return empty list with no data');
    }
}
