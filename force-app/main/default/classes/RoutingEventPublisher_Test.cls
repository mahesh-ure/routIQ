/**
 * @description Test class for RoutingEventPublisher. Validates event construction,
 *              field mapping, dry-run suppression, null safety, and bulk behavior.
 *
 *              Uses @TestVisible mock overrides:
 *              • publishEnabled = false — suppresses EventBus.publish() calls
 *              • lastPublishedEvents — captures built events for assertion
 *
 *              Test strategy:
 *              • publishFromAudit: event fields match audit entry values
 *              • publishFromAudit: dryRun skips publishing entirely
 *              • publishFromAudit: null/empty entries produce no events
 *              • publishFromAudit: correlation IDs map correctly from logIds
 *              • publishFromAudit: error message truncation at 255 chars
 *              • publishFromAudit: bulk — multiple entries produce multiple events
 *
 * @group Test
 */
@IsTest
private class RoutingEventPublisher_Test {

    // ═══════════════════════════════════════════════════════════════════════════
    // Setup
    // ═══════════════════════════════════════════════════════════════════════════

    @TestSetup
    static void setup() {
        // No DML setup needed — publisher uses mock audit entries, not DB records
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // publishFromAudit — Event Field Mapping
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void publishFromAudit_mapsFieldsCorrectly() {
        // Suppress actual EventBus.publish()
        RoutingEventPublisher.publishEnabled = false;

        // Build a mock audit entry
        Routing_Log__c log = new Routing_Log__c();
        log.Record_Id__c             = '500000000000001';
        log.Object_API_Name__c       = 'Case';
        log.Status__c                = 'ASSIGNED';
        log.Assigned_To__c           = '005000000000001AAA';
        log.Config_Developer_Name__c = 'Case_Routing';
        log.Entry_Point__c           = 'LWC';
        log.Routed_At__c             = DateTime.now();
        log.Candidate_Count__c       = 3;
        log.Retry_Count__c           = 1;
        log.Error_Message__c         = null;

        AuditLogger.AuditEntry entry = createMockEntry(log);
        List<AuditLogger.AuditEntry> entries = new List<AuditLogger.AuditEntry>{ entry };

        RoutingRequest request = new RoutingRequest();
        request.dryRun = false;

        Id mockLogId = generateMockId(Routing_Log__c.SObjectType);
        List<Id> logIds = new List<Id>{ mockLogId };

        Test.startTest();
        RoutingEventPublisher.publishFromAudit(entries, request, 'LWC', logIds);
        Test.stopTest();

        // Assert events were built
        List<Routing_Event__e> events = RoutingEventPublisher.lastPublishedEvents;
        System.assertNotEquals(null, events, 'Events should be captured');
        System.assertEquals(1, events.size(), 'Should build exactly 1 event');

        Routing_Event__e evt = events[0];
        System.assertEquals('500000000000001', evt.Record_Id__c,
            'Record_Id__c should map from audit log');
        System.assertEquals('Case', evt.Object_API_Name__c,
            'Object_API_Name__c should map from audit log');
        System.assertEquals('ASSIGNED', evt.Status__c,
            'Status__c should map from audit log');
        System.assertEquals('005000000000001AAA', evt.Assigned_To__c,
            'Assigned_To__c should map from audit log');
        System.assertEquals('Case_Routing', evt.Config_Developer_Name__c,
            'Config_Developer_Name__c should map from audit log');
        System.assertEquals('LWC', evt.Entry_Point__c,
            'Entry_Point__c should map from audit log');
        System.assertEquals(3, evt.Candidate_Count__c,
            'Candidate_Count__c should map from audit log');
        System.assertEquals(1, evt.Retry_Count__c,
            'Retry_Count__c should map from audit log');
        System.assertEquals(false, evt.Is_Dry_Run__c,
            'Is_Dry_Run__c should be false for live runs');
        System.assertEquals(null, evt.Error_Message__c,
            'Error_Message__c should be null on success');
        System.assertEquals(String.valueOf(mockLogId), evt.Correlation_Id__c,
            'Correlation_Id__c should map from logIds');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // publishFromAudit — DryRun Suppression
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void publishFromAudit_dryRun_skipsPublishing() {
        RoutingEventPublisher.publishEnabled = false;
        RoutingEventPublisher.lastPublishedEvents = null;

        Routing_Log__c log = new Routing_Log__c();
        log.Status__c = 'ASSIGNED';
        AuditLogger.AuditEntry entry = createMockEntry(log);

        RoutingRequest request = new RoutingRequest();
        request.dryRun = true;

        Test.startTest();
        RoutingEventPublisher.publishFromAudit(
            new List<AuditLogger.AuditEntry>{ entry },
            request, 'LWC', new List<Id>()
        );
        Test.stopTest();

        System.assertEquals(null, RoutingEventPublisher.lastPublishedEvents,
            'DryRun should skip event building entirely');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // publishFromAudit — Null / Empty Guards
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void publishFromAudit_nullEntries_doesNothing() {
        RoutingEventPublisher.publishEnabled = false;
        RoutingEventPublisher.lastPublishedEvents = null;

        RoutingRequest request = new RoutingRequest();

        Test.startTest();
        RoutingEventPublisher.publishFromAudit(null, request, 'REST', null);
        Test.stopTest();

        System.assertEquals(null, RoutingEventPublisher.lastPublishedEvents,
            'Null entries should produce no events');
    }

    @IsTest
    static void publishFromAudit_emptyEntries_doesNothing() {
        RoutingEventPublisher.publishEnabled = false;
        RoutingEventPublisher.lastPublishedEvents = null;

        RoutingRequest request = new RoutingRequest();

        Test.startTest();
        RoutingEventPublisher.publishFromAudit(
            new List<AuditLogger.AuditEntry>(),
            request, 'REST', new List<Id>()
        );
        Test.stopTest();

        System.assertEquals(null, RoutingEventPublisher.lastPublishedEvents,
            'Empty entries should produce no events');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // publishFromAudit — Error Message Truncation
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void publishFromAudit_longErrorMessage_truncatesAt255() {
        RoutingEventPublisher.publishEnabled = false;

        // Build a 500-char error message
        String longError = 'E'.repeat(500);
        Routing_Log__c log = new Routing_Log__c();
        log.Status__c = 'FAILED';
        log.Error_Message__c = longError;
        AuditLogger.AuditEntry entry = createMockEntry(log);

        RoutingRequest request = new RoutingRequest();
        request.dryRun = false;

        Test.startTest();
        RoutingEventPublisher.publishFromAudit(
            new List<AuditLogger.AuditEntry>{ entry },
            request, 'REST', new List<Id>{ null }
        );
        Test.stopTest();

        List<Routing_Event__e> events = RoutingEventPublisher.lastPublishedEvents;
        System.assertEquals(1, events.size(), 'Should build 1 event');
        System.assertEquals(255, events[0].Error_Message__c.length(),
            'Error message should be truncated to 255 characters');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // publishFromAudit — Bulk (Multiple Entries)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void publishFromAudit_multipleEntries_publishesBulk() {
        RoutingEventPublisher.publishEnabled = false;

        List<AuditLogger.AuditEntry> entries = new List<AuditLogger.AuditEntry>();
        List<Id> logIds = new List<Id>();

        for (Integer i = 0; i < 5; i++) {
            Routing_Log__c log = new Routing_Log__c();
            log.Status__c = (i == 0) ? 'ASSIGNED' : 'NO_MATCH';
            log.Config_Developer_Name__c = 'Config_' + i;
            log.Object_API_Name__c = 'Case';
            entries.add(createMockEntry(log));
            logIds.add(generateMockId(Routing_Log__c.SObjectType));
        }

        RoutingRequest request = new RoutingRequest();
        request.dryRun = false;

        Test.startTest();
        RoutingEventPublisher.publishFromAudit(entries, request, 'InvocableMethod', logIds);
        Test.stopTest();

        List<Routing_Event__e> events = RoutingEventPublisher.lastPublishedEvents;
        System.assertEquals(5, events.size(),
            'Should build 5 events for 5 audit entries');

        System.assertEquals('ASSIGNED', events[0].Status__c,
            'First event should be ASSIGNED');
        System.assertEquals('NO_MATCH', events[1].Status__c,
            'Subsequent events should be NO_MATCH');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // publishFromAudit — Correlation without LogIds
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void publishFromAudit_nullLogIds_correlationIsNull() {
        RoutingEventPublisher.publishEnabled = false;

        Routing_Log__c log = new Routing_Log__c();
        log.Status__c = 'FAILED';
        AuditLogger.AuditEntry entry = createMockEntry(log);

        RoutingRequest request = new RoutingRequest();
        request.dryRun = false;

        Test.startTest();
        RoutingEventPublisher.publishFromAudit(
            new List<AuditLogger.AuditEntry>{ entry },
            request, 'REST', null
        );
        Test.stopTest();

        List<Routing_Event__e> events = RoutingEventPublisher.lastPublishedEvents;
        System.assertEquals(1, events.size(), 'Should build 1 event');
        System.assertEquals(null, events[0].Correlation_Id__c,
            'Correlation_Id__c should be null when logIds is null');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // publishFromAudit — Live publish (EventBus.publish enabled)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void publishFromAudit_livePublish_doesNotThrow() {
        // Leave publishEnabled = true (default) — actually calls EventBus.publish()
        Routing_Log__c log = new Routing_Log__c();
        log.Status__c = 'ASSIGNED';
        log.Config_Developer_Name__c = 'Live_Test';
        AuditLogger.AuditEntry entry = createMockEntry(log);

        RoutingRequest request = new RoutingRequest();
        request.dryRun = false;

        Test.startTest();
        // This should NOT throw — EventBus.publish() is valid in test context
        RoutingEventPublisher.publishFromAudit(
            new List<AuditLogger.AuditEntry>{ entry },
            request, 'LWC', new List<Id>{ null }
        );
        Test.stopTest();

        // If we reach here, publish did not throw
        System.assert(true, 'Live publish should not throw exceptions');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @description Creates a mock AuditEntry wrapping the given Routing_Log__c.
     *              Uses @TestVisible private constructor access.
     */
    private static AuditLogger.AuditEntry createMockEntry(Routing_Log__c log) {
        return new AuditLogger.AuditEntry(log);
    }

    /**
     * @description Generates a mock Salesforce ID for the given SObject type.
     */
    private static Id generateMockId(Schema.SObjectType sObjectType) {
        String prefix = sObjectType.getDescribe().getKeyPrefix();
        return Id.valueOf(prefix + '000000000001');
    }
}
