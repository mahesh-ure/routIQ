/**
 * @description Stateless publisher for Routing_Event__e Platform Events.
 *
 *              Publishes one event per routing outcome (one per ConfigBundle evaluated).
 *              Called from RoutingEngine Phase 5 — AFTER assignment DML and audit flush.
 *
 *              Architecture decisions (CTA):
 *              • PublishAfterCommit — events only fire when the routing transaction commits.
 *                If the transaction rolls back, zero events escape. This guarantees
 *                subscribers never see phantom routing results.
 *              • Fail-safe — EventBus.publish() failures are logged but NEVER thrown.
 *                The routing assignment is the primary outcome; observability events
 *                are secondary. A publish failure must not roll back a successful assignment.
 *              • Bulk-safe — accepts a list of AuditEntry records and publishes all
 *                events in a single EventBus.publish() call (1 DML).
 *              • DryRun-aware — when RoutingRequest.dryRun == true, no events are
 *                published. Simulation mode produces zero side effects.
 *              • ISV-safe — no hardcoded org references. Event fields use generic
 *                Text types (not Lookups) to decouple from subscriber schema.
 *
 *              Governor cost: 1 DML (EventBus.publish counts against DML limit).
 *
 *              Subscribers can consume events via:
 *              • Apex Trigger on Routing_Event__e (runs in its own transaction)
 *              • Flow — Platform Event-Triggered Flow
 *              • LWC — lightning/empApi (CometD streaming)
 *              • External — Pub/Sub API (gRPC) or CometD
 *
 * @group Worker
 */
public with sharing class RoutingEventPublisher {

    private static final String CLS = 'RoutingEventPublisher';

    // ─── Test Hooks ───────────────────────────────────────────────────────────

    /**
     * @description When true (default), events are published normally.
     *              Set to false in tests to suppress EventBus.publish() calls
     *              while still capturing built events in lastPublishedEvents.
     */
    @TestVisible
    private static Boolean publishEnabled = true;

    /**
     * @description Captures the last batch of events that were built for publishing.
     *              Populated regardless of publishEnabled — allows test assertions
     *              on event field values without actually publishing to the bus.
     */
    @TestVisible
    private static List<Routing_Event__e> lastPublishedEvents;

    // ─── Public API ───────────────────────────────────────────────────────────

    /**
     * @description Builds and publishes Platform Events from audit entries.
     *              Called from RoutingEngine Phase 5 (finally block).
     *
     *              Skips publishing when:
     *              • request.dryRun == true (simulation mode)
     *              • entries list is null or empty
     *              • publishEnabled == false (test override)
     *
     * @param entries    AuditEntry list collected during bundle processing
     * @param request    Original routing request (checked for dryRun flag)
     * @param entryPoint Integration surface (InvocableMethod, REST, LWC, etc.)
     * @param logIds     Routing_Log__c IDs from AuditLogger.flush() — used as Correlation_Id__c
     */
    public static void publishFromAudit(
        List<AuditLogger.AuditEntry> entries,
        RoutingRequest request,
        String entryPoint,
        List<Id> logIds
    ) {
        // ── Guard clauses ───────────────────────────────────────────────
        if (entries == null || entries.isEmpty()) {
            return;
        }

        // DryRun: skip ALL side effects — no DML, no EventBus.publish()
        if (request != null && request.dryRun == true) {
            return;
        }

        // ── Build events ────────────────────────────────────────────────
        List<Routing_Event__e> events = new List<Routing_Event__e>();

        for (Integer i = 0; i < entries.size(); i++) {
            AuditLogger.AuditEntry entry = entries[i];
            Routing_Log__c log = entry.record;

            Routing_Event__e evt = new Routing_Event__e();
            evt.Record_Id__c              = log.Record_Id__c;
            evt.Object_API_Name__c        = log.Object_API_Name__c;
            evt.Status__c                 = log.Status__c;
            evt.Assigned_To__c            = log.Assigned_To__c;
            evt.Config_Developer_Name__c  = log.Config_Developer_Name__c;
            evt.Entry_Point__c            = log.Entry_Point__c;
            evt.Routed_At__c              = log.Routed_At__c;
            evt.Candidate_Count__c        = log.Candidate_Count__c;
            evt.Retry_Count__c            = log.Retry_Count__c;
            evt.Is_Dry_Run__c             = false;
            evt.Error_Message__c          = truncate(log.Error_Message__c, 255);

            // Correlation: link to Routing_Log__c for full audit detail
            if (logIds != null && i < logIds.size() && logIds[i] != null) {
                evt.Correlation_Id__c = String.valueOf(logIds[i]);
            }

            events.add(evt);
        }

        // ── Capture for test assertions (always, even if publish disabled) ──
        lastPublishedEvents = events;

        // ── Publish ─────────────────────────────────────────────────────
        if (!publishEnabled) {
            return; // Test mode — events captured but not published
        }

        try {
            List<Database.SaveResult> results = EventBus.publish(events);
            logPublishResults(results, events);
        } catch (Exception ex) {
            // Fail-safe: event publish failure must NEVER propagate.
            // The routing assignment is already committed (or about to be).
            Logger.error('EventBus.publish() threw unexpectedly: ' + ex.getMessage())
                .category(Logger.Category.AUDIT)
                .inClass(CLS).inMethod('publishFromAudit')
                .withException(ex)
                .log();
        }
    }

    // ─── Private Helpers ──────────────────────────────────────────────────────

    /**
     * @description Logs publish results. Successes are silent; failures are logged
     *              as warnings (not errors) because event publish is non-critical.
     */
    private static void logPublishResults(
        List<Database.SaveResult> results,
        List<Routing_Event__e> events
    ) {
        Integer failCount = 0;

        for (Integer i = 0; i < results.size(); i++) {
            Database.SaveResult sr = results[i];

            if (!sr.isSuccess()) {
                failCount++;
                String errMsg = formatErrors(sr.getErrors());
                String config = (i < events.size())
                    ? events[i].Config_Developer_Name__c
                    : 'unknown';

                Logger.warn('Routing_Event__e publish failed | config='
                        + config + ' | errors=' + errMsg)
                    .category(Logger.Category.AUDIT)
                    .inClass(CLS).inMethod('logPublishResults')
                    .log();
            }
        }

        if (failCount == 0 && !results.isEmpty()) {
            Logger.info('Published ' + results.size() + ' Routing_Event__e record(s)')
                .category(Logger.Category.AUDIT)
                .inClass(CLS).inMethod('publishFromAudit')
                .log();
        }
    }

    /**
     * @description Formats Database.Error list for diagnostic logging.
     */
    private static String formatErrors(List<Database.Error> errors) {
        if (errors == null || errors.isEmpty()) {
            return System.Label.URE_UNKNOWN_ERROR;
        }
        List<String> messages = new List<String>();
        for (Database.Error err : errors) {
            messages.add(err.getStatusCode() + ': ' + err.getMessage());
        }
        return String.join(messages, '; ');
    }

    /**
     * @description Safely truncates a string to maxLen characters.
     *              Prevents Platform Event payload from exceeding field limits.
     */
    private static String truncate(String value, Integer maxLen) {
        if (value == null) {
            return null;
        }
        return (value.length() > maxLen) ? value.substring(0, maxLen) : value;
    }
}
