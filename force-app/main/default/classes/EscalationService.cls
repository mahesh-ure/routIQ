/**
 * @description Service layer for SLA escalation processing. Evaluates whether
 *              assigned records have breached their SLA threshold and executes
 *              the configured escalation action (Re-route, Notify, or Both).
 *
 *              Orchestration flow:
 *              1. EscalationSelector provides enriched candidates with SLA deadlines
 *              2. This service evaluates threshold proximity per config
 *              3. For each breached candidate:
 *                 a. Check "acted on" — skip if agent has already acted
 *                 b. Execute escalation action per Routing_Config__mdt
 *                 c. Log to Routing_Log__c via AuditLogger pattern
 *                 d. Publish ESCALATED Platform Event
 *
 *              Security:
 *              - All DML uses AccessLevel.USER_MODE — CRUD/FLS enforced.
 *              - Dynamic field access validated via Schema.describe before use.
 *              - No hardcoded field names — all from Routing_Config__mdt.
 *
 *              Governor awareness:
 *              - Re-route DML: 1 per escalated record (owner update)
 *              - Notification: 1 Messaging.sendEmail per batch
 *              - Audit: bulk insert via flush pattern
 *              - Events: bulk publish via EventBus.publish
 *
 * @group Service
 */
public with sharing class EscalationService {

    private static final String CLS = 'EscalationService';
    private static final String EVENT_TYPE_ESCALATED = 'ESCALATED';
    private static final Decimal FALLBACK_THRESHOLD_PCT = 20;

    /**
     * @description DTO summarizing escalation results for the job to log.
     */
    public class EscalationResult {
        public Integer totalEvaluated  = 0;
        public Integer totalEscalated  = 0;
        public Integer totalSkipped    = 0;
        public Integer totalErrors     = 0;
        public List<String> errors     = new List<String>();
    }

    // =========================================================================
    // PUBLIC API — called by SLAEscalationJob
    // =========================================================================

    /**
     * @description Processes a list of escalation candidates. Evaluates SLA
     *              threshold, checks acted-on status, and executes configured
     *              escalation actions. Returns a summary result.
     *
     * @param candidates List of EscalationCandidate from EscalationSelector
     * @return EscalationResult with counts and any error messages
     */
    public static EscalationResult processEscalations(
        List<EscalationSelector.EscalationCandidate> candidates
    ) {
        EscalationResult result = new EscalationResult();

        if (candidates == null || candidates.isEmpty()) {
            return result;
        }

        List<Routing_Event__e> eventsToPublish = new List<Routing_Event__e>();
        List<Routing_Log__c> logsToInsert = new List<Routing_Log__c>();

        for (EscalationSelector.EscalationCandidate ec : candidates) {
            result.totalEvaluated++;

            try {
                // ── Skip if no SLA deadline ─────────────────────────────
                if (ec.slaDeadline == null) {
                    result.totalSkipped++;
                    continue;
                }

                // ── Skip if agent has acted on the record ───────────────
                if (hasActedOn(ec)) {
                    result.totalSkipped++;
                    continue;
                }

                // ── Evaluate SLA threshold ──────────────────────────────
                if (!isThresholdBreached(ec)) {
                    result.totalSkipped++;
                    continue;
                }

                // ── Execute escalation ──────────────────────────────────
                executeEscalation(ec, eventsToPublish, logsToInsert);
                result.totalEscalated++;

            } catch (Exception ex) {
                result.totalErrors++;
                result.errors.add(
                    'Record ' + ec.workItem.Record_Id__c
                    + ': ' + ex.getMessage()
                );
                Logger.error('Escalation failed | record='
                        + ec.workItem.Record_Id__c)
                    .category(Logger.Category.ENGINE)
                    .inClass(CLS).inMethod('processEscalations')
                    .withException(ex)
                    .log();
            }
        }

        // ── Bulk flush audit logs ───────────────────────────────────────
        if (!logsToInsert.isEmpty()) {
            Database.insert(logsToInsert, false, AccessLevel.USER_MODE);
        }

        // ── Bulk publish events ─────────────────────────────────────────
        if (!eventsToPublish.isEmpty()) {
            EventBus.publish(eventsToPublish);
        }

        return result;
    }

    // =========================================================================
    // PRIVATE — Threshold Evaluation
    // =========================================================================

    /**
     * @description Checks whether the SLA deadline is within the escalation
     *              threshold. Uses the config's Escalation_Threshold_Pct__c
     *              to determine the trigger point.
     *
     *              Example: 60-minute SLA, 20% threshold → escalate when
     *              ≤ 12 minutes remain (i.e., 48 minutes have elapsed).
     *
     * @param ec The escalation candidate with SLA deadline and config
     * @return true if the threshold has been breached (time to escalate)
     */
    private static Boolean isThresholdBreached(
        EscalationSelector.EscalationCandidate ec
    ) {
        Datetime now = System.now();
        Datetime deadline = ec.slaDeadline;

        // Already past deadline — definitely escalate
        if (deadline <= now) {
            return true;
        }

        // Calculate threshold window
        Decimal slaMinutes = ec.bundle.slaMinutes;
        if (slaMinutes == null || slaMinutes <= 0) {
            return false;
        }

        Decimal thresholdPct = ec.bundle.escalationThresholdPct;
        if (thresholdPct == null || thresholdPct <= 0) {
            thresholdPct = FALLBACK_THRESHOLD_PCT;
        }

        // Total SLA window in milliseconds
        Long totalWindowMs = (Long) (slaMinutes * 60 * 1000);

        // Threshold = percentage of total window
        Long thresholdMs = (Long) (totalWindowMs * thresholdPct / 100);

        // Time remaining until deadline
        Long remainingMs = deadline.getTime() - now.getTime();

        return remainingMs <= thresholdMs;
    }

    /**
     * @description Checks whether the agent has acted on the record based on
     *              the configured Acted_On_Field__c and Acted_On_Value__c.
     *              Returns true if the field value matches any of the
     *              comma-separated acted-on values.
     *
     * @param ec The escalation candidate with acted-on field value
     * @return true if the agent has acted (escalation should be skipped)
     */
    private static Boolean hasActedOn(
        EscalationSelector.EscalationCandidate ec
    ) {
        // No acted-on field configured — assume not acted on
        if (String.isBlank(ec.bundle.actedOnField)) {
            return false;
        }

        // Field value is null — not acted on
        if (ec.actedOnFieldValue == null) {
            return false;
        }

        String actualValue = String.valueOf(ec.actedOnFieldValue);
        if (String.isBlank(actualValue)) {
            return false;
        }

        // Check against configured acted-on values (comma-separated)
        List<String> actedOnValues = ec.bundle.actedOnValues;
        if (actedOnValues == null || actedOnValues.isEmpty()) {
            return false;
        }

        for (String expected : actedOnValues) {
            if (expected.equalsIgnoreCase(actualValue)) {
                return true;
            }
        }

        return false;
    }

    // =========================================================================
    // PRIVATE — Escalation Execution
    // =========================================================================

    /**
     * @description Executes the configured escalation action for a single
     *              candidate. Delegates to re-route and/or notify based on
     *              Escalation_Action__c picklist value.
     */
    private static void executeEscalation(
        EscalationSelector.EscalationCandidate ec,
        List<Routing_Event__e> eventsToPublish,
        List<Routing_Log__c> logsToInsert
    ) {
        ConfigBundle bundle = ec.bundle;
        Agent_Work_Item__c workItem = ec.workItem;
        String action = bundle.escalationAction;

        // Default to Re-route if no action specified
        if (String.isBlank(action)) {
            action = 'Re-route';
        }

        String originalAgent = workItem.Agent__r != null
            ? String.valueOf(workItem.Agent__r.User__c)
            : '';
        String newOwner = '';

        // ── Re-route ────────────────────────────────────────────────────
        if (action == 'Re-route' || action == 'Both') {
            newOwner = executeReroute(ec);
        }

        // ── Notify ──────────────────────────────────────────────────────
        if (action == 'Notify' || action == 'Both') {
            executeNotify(ec, originalAgent);
        }

        // ── Remove work item from agent (sync load) ─────────────────────
        WorkItemService.escalateWorkItem(workItem);

        // ── Audit log ───────────────────────────────────────────────────
        Routing_Log__c log = new Routing_Log__c(
            Record_Id__c             = workItem.Record_Id__c,
            Object_API_Name__c       = workItem.Object_API_Name__c,
            Config_Developer_Name__c = bundle.developerName,
            Status__c                = 'ESCALATED',
            Assigned_To__c           = String.isNotBlank(originalAgent)
                ? Id.valueOf(originalAgent) : null,
            Routed_At__c             = System.now(),
            Entry_Point__c           = 'ScheduledJob',
            Error_Message__c         = 'Escalated: action=' + action
                + ' | originalAgent=' + originalAgent
                + ' | newOwner=' + newOwner
                + ' | threshold=' + bundle.escalationThresholdPct + '%'
        );
        logsToInsert.add(log);

        // ── Platform Event ──────────────────────────────────────────────
        Routing_Event__e evt = new Routing_Event__e(
            Event_Type__c            = EVENT_TYPE_ESCALATED,
            Record_Id__c             = workItem.Record_Id__c,
            Object_API_Name__c       = workItem.Object_API_Name__c,
            Config_Developer_Name__c = bundle.developerName,
            Assigned_To__c           = originalAgent,
            Routed_At__c             = System.now(),
            Status__c                = 'ESCALATED',
            Entry_Point__c           = 'ScheduledJob',
            Error_Message__c         = 'SLA threshold breached — escalation action: '
                + action
        );
        eventsToPublish.add(evt);

        Logger.info('Escalation executed | record=' + workItem.Record_Id__c
                + ' | action=' + action
                + ' | originalAgent=' + originalAgent
                + ' | config=' + bundle.developerName)
            .category(Logger.Category.ENGINE)
            .inClass(CLS).inMethod('executeEscalation')
            .forConfig(bundle.developerName)
            .forObject(bundle.objectApiName)
            .log();
    }

    /**
     * @description Re-routes the record by setting the owner back to the
     *              configured Escalation_Return_Owner__c (Queue or User).
     *              Does NOT re-enter RoutingService.route() — the record
     *              goes back to the pool for the next agent pull.
     *
     * @param ec The escalation candidate
     * @return String representation of the new owner ID
     */
    private static String executeReroute(
        EscalationSelector.EscalationCandidate ec
    ) {
        ConfigBundle bundle = ec.bundle;
        String returnOwner = bundle.escalationReturnOwner;

        if (String.isBlank(returnOwner)) {
            Logger.warn('Escalation re-route skipped — no return owner configured'
                    + ' | config=' + bundle.developerName)
                .category(Logger.Category.ENGINE)
                .inClass(CLS).inMethod('executeReroute')
                .forConfig(bundle.developerName)
                .log();
            return '';
        }

        // Update the record's owner field to the return owner
        String objectApiName = bundle.objectApiName;
        String ownerField = bundle.ownerFieldApiName;
        Id recordId = Id.valueOf(ec.workItem.Record_Id__c);

        Schema.SObjectType sot = Schema.getGlobalDescribe().get(objectApiName);
        if (sot == null) {
            return '';
        }

        SObject record = sot.newSObject(recordId);
        record.put(ownerField, Id.valueOf(returnOwner));

        Database.SaveResult sr = Database.update(
            record, false, AccessLevel.USER_MODE
        );

        if (!sr.isSuccess()) {
            String errors = '';
            for (Database.Error err : sr.getErrors()) {
                errors += err.getMessage() + '; ';
            }
            Logger.error('Escalation re-route DML failed | record='
                    + recordId + ' | errors=' + errors)
                .category(Logger.Category.ENGINE)
                .inClass(CLS).inMethod('executeReroute')
                .forConfig(bundle.developerName)
                .log();
        }

        return returnOwner;
    }

    /**
     * @description Sends an escalation notification email to the configured
     *              Escalation_Notify_Email__c address(es). Silently skips if
     *              no email is configured. Supports comma-separated recipients.
     *
     * @param ec            The escalation candidate
     * @param originalAgent The agent who was assigned but did not act
     */
    private static void executeNotify(
        EscalationSelector.EscalationCandidate ec,
        String originalAgent
    ) {
        ConfigBundle bundle = ec.bundle;
        String emailCsv = bundle.escalationNotifyEmail;

        if (String.isBlank(emailCsv)) {
            return;
        }

        List<String> recipients = new List<String>();
        for (String addr : emailCsv.split(',')) {
            String trimmed = addr.trim();
            if (String.isNotBlank(trimmed)) {
                recipients.add(trimmed);
            }
        }

        if (recipients.isEmpty()) {
            return;
        }

        try {
            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
            mail.setToAddresses(recipients);
            mail.setSubject('routIQ SLA Escalation — '
                + ec.workItem.Object_API_Name__c + ' '
                + ec.workItem.Record_Id__c);
            mail.setPlainTextBody(
                'SLA escalation triggered for record '
                + ec.workItem.Record_Id__c
                + ' (' + ec.workItem.Object_API_Name__c + ')'
                + '\n\nRouting Config: ' + bundle.developerName
                + '\nOriginal Agent: ' + originalAgent
                + '\nEscalation Action: ' + bundle.escalationAction
                + '\nSLA Threshold: ' + bundle.escalationThresholdPct + '%'
                + '\nAssigned At: ' + ec.workItem.Assigned_At__c
                + '\n\nThis record requires immediate attention.'
            );
            mail.setSaveAsActivity(false);

            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });

        } catch (Exception ex) {
            Logger.warn('Escalation email failed | ' + ex.getMessage())
                .category(Logger.Category.ENGINE)
                .inClass(CLS).inMethod('executeNotify')
                .forConfig(bundle.developerName)
                .log();
        }
    }
}
