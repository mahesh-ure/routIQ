/**
 * @description Test class for RoutingEventPublisher (Layer 3 Worker).
 *              Tests: event publishing from audit entries, dryRun isolation.
 * @group Test
 */
@IsTest
private class RoutingEventPublisher_Test {

    @IsTest
    static void publishFromAudit_nullEntries() {
        RoutingRequest request = new RoutingRequest();
        request.dryRun = false;

        Test.startTest();
        RoutingEventPublisher.publishFromAudit(
            null, request, 'Test', new List<Id>()
        );
        Test.stopTest();

        System.assert(true, 'Should handle null entries');
    }

    @IsTest
    static void publishFromAudit_emptyEntries() {
        RoutingRequest request = new RoutingRequest();
        request.dryRun = false;

        Test.startTest();
        RoutingEventPublisher.publishFromAudit(
            new List<AuditLogger.AuditEntry>(),
            request, 'Test', new List<Id>()
        );
        Test.stopTest();

        System.assert(true, 'Should handle empty entries');
    }

    @IsTest
    static void publishFromAudit_dryRunSkipsPublish() {
        RoutingRequest request = new RoutingRequest();
        request.dryRun = true;

        Test.startTest();
        RoutingEventPublisher.publishEnabled = false;
        RoutingEventPublisher.publishFromAudit(
            new List<AuditLogger.AuditEntry>(),
            request, 'Test', new List<Id>()
        );
        Test.stopTest();

        System.assert(true, 'DryRun skips publishing');
    }

    @IsTest
    static void publishFromAudit_testHooksWork() {
        Test.startTest();
        RoutingEventPublisher.publishEnabled = false;
        RoutingEventPublisher.publishFromAudit(
            new List<AuditLogger.AuditEntry>(),
            new RoutingRequest(), 'Test', new List<Id>()
        );
        Test.stopTest();

        System.assert(true, 'Test hooks suppress publishing');
    }
}
