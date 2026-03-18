/**
 * @description Creates insert-only Routing_Log__c audit records from routing outcomes.
 *
 *              Routing_Log__c is the BUSINESS audit trail — always written, never disabled.
 *              It powers the RoutingStatus LWC, Health Dashboard, and compliance reports.
 *              This is distinct from URE_Logger (diagnostic observability that CAN be
 *              turned off via URE_Log_Config__mdt).
 *
 *              Design:
 *              • Thin mapper — translates AssignmentOutcome + context into Routing_Log__c fields.
 *              • Bulk-aware — collects all outcomes per transaction, single DML insert.
 *              • PII-safe — Query_Bind_Snapshot__c stores bind KEYS and list SIZES only,
 *                never raw values. AppExchange security review compliant.
 *              • DML uses AccessLevel.USER_MODE for CRUD/FLS enforcement.
 *
 *              Usage (called by RoutingEngine):
 *                List<AuditLogger.AuditEntry> entries = new List<AuditLogger.AuditEntry>();
 *                entries.add(AuditLogger.createEntry(outcome, bundle, request, spec));
 *                List<Id> logIds = AuditLogger.flush(entries, agentUserId, entryPoint);
 *
 *              Governor cost: 1 DML per flush (bulk insert). Zero SOQL.
 *
 * @group Worker
 */
public with sharing class AuditLogger {

    // ─── Inner Value Object ───────────────────────────────────────────────────

    /**
     * @description Pre-mapped Routing_Log__c record ready for bulk insert.
     *              Built by createEntry(), collected by the engine, flushed once.
     */
    public class AuditEntry {
        public Routing_Log__c record { get; private set; }

        @TestVisible
        private AuditEntry(Routing_Log__c record) {
            this.record = record;
        }
    }

    // ─── Public API ───────────────────────────────────────────────────────────

    /**
     * @description Maps a single AssignmentOutcome into an AuditEntry ready for flush.
     *              Called once per ConfigBundle evaluated by RoutingEngine.
     *
     * @param outcome    Assignment result from AssignmentResolver
     * @param bundle     The config bundle that was evaluated
     * @param agentUserId Agent who initiated the routing request (pull model)
     * @param entryPoint Integration surface (InvocableMethod, REST, LWC, GlobalAction)
     * @param spec       QuerySpec for bind snapshot (may be null if query was never built)
     * @return AuditEntry ready to be added to the flush list
     */
    public static AuditEntry createEntry(
        AssignmentResolver.AssignmentOutcome outcome,
        ConfigBundle bundle,
        Id agentUserId,
        String entryPoint,
        QuerySpec spec
    ) {
        Routing_Log__c log = new Routing_Log__c();

        // ─── From AssignmentOutcome ───────────────────────────────────────
        log.Record_Id__c = (outcome.recordId != null)
            ? String.valueOf(outcome.recordId)
            : null;
        log.Status__c              = outcome.status;
        log.Error_Message__c       = outcome.errorMessage;
        log.Retry_Count__c         = outcome.retryCount;
        log.Lock_Contention__c     = outcome.lockContention;
        log.Candidate_Count__c     = outcome.candidateCount;

        // ─── From ConfigBundle ────────────────────────────────────────────
        log.Config_Developer_Name__c = bundle.developerName;
        log.Object_API_Name__c       = bundle.objectApiName;

        // ─── From Request Context ─────────────────────────────────────────
        log.Assigned_To__c = (outcome.success) ? agentUserId : null;
        log.Entry_Point__c = entryPoint;
        log.Routed_At__c   = System.now();

        // ─── Bind Snapshot (PII-safe) ─────────────────────────────────────
        log.Query_Bind_Snapshot__c = sanitizeBindSnapshot(spec);

        return new AuditEntry(log);
    }

    /**
     * @description Bulk-inserts all collected AuditEntries in a single DML call.
     *              Returns the Ids of successfully inserted Routing_Log__c records,
     *              indexed in the same order as the input list.
     *
     *              On partial failure (allOrNone=false), logs errors at ERROR level
     *              but does not throw — routing should not fail because audit logging failed.
     *
     * @param entries  List of AuditEntries from createEntry() calls
     * @return List of inserted Routing_Log__c Ids (null for any failed rows)
     */
    public static List<Id> flush(List<AuditEntry> entries) {
        List<Id> logIds = new List<Id>();

        if (entries == null || entries.isEmpty()) {
            return logIds;
        }

        // Extract SObject records for DML
        List<Routing_Log__c> logs = new List<Routing_Log__c>();
        for (AuditEntry entry : entries) {
            logs.add(entry.record);
        }

        // Single bulk insert — 1 DML statement regardless of count
        List<Database.SaveResult> results = Database.insert(
            logs,
            false,                  // allOrNone = false — partial success allowed
            AccessLevel.USER_MODE   // CRUD/FLS enforced
        );

        for (Integer i = 0; i < results.size(); i++) {
            Database.SaveResult sr = results[i];
            if (sr.isSuccess()) {
                logIds.add(sr.getId());
            } else {
                logIds.add(null);
                System.debug(LoggingLevel.ERROR,
                    'AuditLogger: failed to insert Routing_Log__c for config='
                    + logs[i].Config_Developer_Name__c
                    + ': ' + formatErrors(sr.getErrors()));
            }
        }

        return logIds;
    }

    // ─── Private Helpers ──────────────────────────────────────────────────────

    /**
     * @description Builds a PII-safe JSON snapshot of bind variable metadata.
     *              Stores bind KEY names and the SIZE of each list — never raw values.
     *
     *              Example output:
     *              {"b0":{"type":"List<String>","size":2},"b1":{"type":"List<Decimal>","size":1},"rtFilter":{"type":"List<String>","size":3}}
     *
     *              This satisfies AppExchange security review: no customer data in
     *              Routing_Log__c records. Admins can still diagnose query shape issues.
     *
     * @param spec QuerySpec from DynamicQueryBuilder (may be null)
     * @return JSON string or null if no spec/binds exist
     */
    @TestVisible
    private static String sanitizeBindSnapshot(QuerySpec spec) {
        if (spec == null || spec.bindMap == null || spec.bindMap.isEmpty()) {
            return null;
        }

        Map<String, Object> sanitized = new Map<String, Object>();

        for (String key : spec.bindMap.keySet()) {
            Object val = spec.bindMap.get(key);
            Map<String, Object> meta = new Map<String, Object>();

            if (val instanceof List<Object>) {
                List<Object> listVal = (List<Object>) val;
                meta.put('type', 'List');
                meta.put('size', listVal.size());
            } else if (val instanceof List<String>) {
                List<String> listVal = (List<String>) val;
                meta.put('type', 'List<String>');
                meta.put('size', listVal.size());
            } else if (val instanceof List<Decimal>) {
                List<Decimal> listVal = (List<Decimal>) val;
                meta.put('type', 'List<Decimal>');
                meta.put('size', listVal.size());
            } else if (val instanceof List<Boolean>) {
                List<Boolean> listVal = (List<Boolean>) val;
                meta.put('type', 'List<Boolean>');
                meta.put('size', listVal.size());
            } else if (val instanceof List<Date>) {
                List<Date> listVal = (List<Date>) val;
                meta.put('type', 'List<Date>');
                meta.put('size', listVal.size());
            } else if (val instanceof List<DateTime>) {
                List<DateTime> listVal = (List<DateTime>) val;
                meta.put('type', 'List<DateTime>');
                meta.put('size', listVal.size());
            } else if (val instanceof Id) {
                meta.put('type', 'Id');
                meta.put('size', 1);
            } else {
                meta.put('type', getTypeName(val));
                meta.put('size', 1);
            }

            sanitized.put(key, meta);
        }

        return JSON.serialize(sanitized);
    }

    /**
     * @description Returns a safe type name for scalar bind values.
     */
    private static String getTypeName(Object val) {
        if (val instanceof String)   { return 'String'; }
        if (val instanceof Decimal)  { return 'Decimal'; }
        if (val instanceof Boolean)  { return 'Boolean'; }
        if (val instanceof Date)     { return 'Date'; }
        if (val instanceof DateTime) { return 'DateTime'; }
        if (val instanceof Id)       { return 'Id'; }
        return 'Object';
    }

    /**
     * @description Formats Database.Error list for debug logging.
     */
    private static String formatErrors(List<Database.Error> errors) {
        if (errors == null || errors.isEmpty()) {
            return 'Unknown error.';
        }
        List<String> messages = new List<String>();
        for (Database.Error err : errors) {
            messages.add(err.getStatusCode() + ': ' + err.getMessage());
        }
        return String.join(messages, '; ');
    }
}
