/**
 * @description Tests for AuditLogger.enrichWithAnalytics() — validates
 *              duration computation, SLA evaluation, and agent name
 *              denormalization on Routing_Log__c records.
 *
 * @group Test
 */
@IsTest
private class AuditLogger_Analytics_Test {

    @IsTest
    static void testEnrichWithAnalytics_successEntry_slaConfigured() {
        // Build a mock AuditEntry with a Success log record
        Routing_Log__c log = new Routing_Log__c(
            Status__c = 'Success',
            Config_Developer_Name__c = 'Test_Config',
            Object_API_Name__c = 'Case',
            Record_Id__c = '001000000099000001',
            Routed_At__c = System.now(),
            Assigned_To__c = UserInfo.getUserId(),
            Entry_Point__c = 'LWC'
        );
        AuditLogger.AuditEntry entry = new AuditLogger.AuditEntry(log);

        // Build a ConfigBundle with SLA_Minutes__c = 5
        Routing_Config__mdt config = new Routing_Config__mdt(
            DeveloperName = 'Test_Config',
            Object_API_Name__c = 'Case',
            Owner_Field_API_Name__c = 'OwnerId',
            Priority_Weight__c = 1,
            Candidate_Limit__c = 50,
            SLA_Minutes__c = 5
        );
        ConfigBundle bundle = new ConfigBundle(
            config,
            new List<Routing_Condition__mdt>(),
            new List<Routing_Priority__mdt>()
        );

        Long requestStartMs = System.currentTimeMillis() - 2000; // 2 seconds ago

        Test.startTest();
        AuditLogger.enrichWithAnalytics(
            new List<AuditLogger.AuditEntry>{ entry },
            new List<ConfigBundle>{ bundle },
            requestStartMs,
            'Test Agent Name'
        );
        Test.stopTest();

        // Duration should be approximately 2000ms (with some tolerance)
        System.assertNotEquals(null, log.Assignment_Duration_Ms__c, 'Duration should be set');
        System.assert(log.Assignment_Duration_Ms__c >= 1500, 'Duration should be ~2000ms: ' + log.Assignment_Duration_Ms__c);

        // SLA should be Met (2s < 5min)
        System.assertEquals('Met', log.SLA_Met__c, 'SLA should be Met (2s < 5min)');

        // Agent name
        System.assertEquals('Test Agent Name', log.Agent_Name__c, 'Agent name should be set');
    }

    @IsTest
    static void testEnrichWithAnalytics_successEntry_slaBreached() {
        Routing_Log__c log = new Routing_Log__c(
            Status__c = 'Success',
            Config_Developer_Name__c = 'Test_Config',
            Object_API_Name__c = 'Case',
            Record_Id__c = '001000000099000002',
            Routed_At__c = System.now(),
            Assigned_To__c = UserInfo.getUserId(),
            Entry_Point__c = 'LWC'
        );
        AuditLogger.AuditEntry entry = new AuditLogger.AuditEntry(log);

        Routing_Config__mdt config = new Routing_Config__mdt(
            DeveloperName = 'Test_Config',
            Object_API_Name__c = 'Case',
            Owner_Field_API_Name__c = 'OwnerId',
            Priority_Weight__c = 1,
            Candidate_Limit__c = 50,
            SLA_Minutes__c = 0  // SLA set to 0 minutes → effectively breached
        );
        ConfigBundle bundle = new ConfigBundle(
            config,
            new List<Routing_Condition__mdt>(),
            new List<Routing_Priority__mdt>()
        );

        // Request started 2 seconds ago
        Long requestStartMs = System.currentTimeMillis() - 2000;

        Test.startTest();
        AuditLogger.enrichWithAnalytics(
            new List<AuditLogger.AuditEntry>{ entry },
            new List<ConfigBundle>{ bundle },
            requestStartMs,
            'Agent Breached'
        );
        Test.stopTest();

        // SLA_Minutes = 0 → SLA not tracked (null)
        System.assertEquals(null, log.SLA_Met__c, 'SLA should be null when SLA_Minutes is 0');
    }

    @IsTest
    static void testEnrichWithAnalytics_failedEntry_noEnrichment() {
        Routing_Log__c log = new Routing_Log__c(
            Status__c = 'Failed',
            Config_Developer_Name__c = 'Test_Config',
            Object_API_Name__c = 'Case',
            Record_Id__c = '001000000099000003',
            Routed_At__c = System.now(),
            Entry_Point__c = 'REST'
        );
        AuditLogger.AuditEntry entry = new AuditLogger.AuditEntry(log);

        Routing_Config__mdt config = new Routing_Config__mdt(
            DeveloperName = 'Test_Config',
            Object_API_Name__c = 'Case',
            Owner_Field_API_Name__c = 'OwnerId',
            Priority_Weight__c = 1,
            Candidate_Limit__c = 50,
            SLA_Minutes__c = 5
        );
        ConfigBundle bundle = new ConfigBundle(
            config,
            new List<Routing_Condition__mdt>(),
            new List<Routing_Priority__mdt>()
        );

        Long requestStartMs = System.currentTimeMillis() - 1000;

        Test.startTest();
        AuditLogger.enrichWithAnalytics(
            new List<AuditLogger.AuditEntry>{ entry },
            new List<ConfigBundle>{ bundle },
            requestStartMs,
            'Agent Name'
        );
        Test.stopTest();

        // Failed entries get no duration or SLA
        System.assertEquals(null, log.Assignment_Duration_Ms__c, 'Failed entry should have no duration');
        System.assertEquals(null, log.SLA_Met__c, 'Failed entry should have no SLA');
        // No Assigned_To → no agent name
        System.assertEquals(null, log.Agent_Name__c, 'Failed entry with no assignee should have no agent name');
    }

    @IsTest
    static void testEnrichWithAnalytics_nullEntries() {
        // Should not throw
        Test.startTest();
        AuditLogger.enrichWithAnalytics(null, null, null, null);
        AuditLogger.enrichWithAnalytics(new List<AuditLogger.AuditEntry>(), new List<ConfigBundle>(), 0L, '');
        Test.stopTest();

        // No assertions needed — just verifying no exceptions
        System.assert(true, 'Should handle null/empty gracefully');
    }

    @IsTest
    static void testEnrichWithAnalytics_noSlaConfigured() {
        Routing_Log__c log = new Routing_Log__c(
            Status__c = 'Success',
            Config_Developer_Name__c = 'No_SLA_Config',
            Object_API_Name__c = 'Lead',
            Record_Id__c = '001000000099000004',
            Routed_At__c = System.now(),
            Assigned_To__c = UserInfo.getUserId(),
            Entry_Point__c = 'InvocableMethod'
        );
        AuditLogger.AuditEntry entry = new AuditLogger.AuditEntry(log);

        // Config with no SLA (null)
        Routing_Config__mdt config = new Routing_Config__mdt(
            DeveloperName = 'No_SLA_Config',
            Object_API_Name__c = 'Lead',
            Owner_Field_API_Name__c = 'OwnerId',
            Priority_Weight__c = 1,
            Candidate_Limit__c = 50
            // SLA_Minutes__c intentionally omitted → null
        );
        ConfigBundle bundle = new ConfigBundle(
            config,
            new List<Routing_Condition__mdt>(),
            new List<Routing_Priority__mdt>()
        );

        Long requestStartMs = System.currentTimeMillis() - 500;

        Test.startTest();
        AuditLogger.enrichWithAnalytics(
            new List<AuditLogger.AuditEntry>{ entry },
            new List<ConfigBundle>{ bundle },
            requestStartMs,
            'Agent NoSLA'
        );
        Test.stopTest();

        // Duration should be set (success)
        System.assertNotEquals(null, log.Assignment_Duration_Ms__c, 'Duration should be set for success');
        // SLA not tracked
        System.assertEquals(null, log.SLA_Met__c, 'SLA should be null when not configured');
        // Agent name set
        System.assertEquals('Agent NoSLA', log.Agent_Name__c, 'Agent name should be set');
    }
}
