/**
 * @description Creates insert-only Routing_Log__c audit records from routing outcomes.
 *
 *              Routing_Log__c is the BUSINESS audit trail — always written, never disabled.
 *              This is distinct from Logger (diagnostic observability that CAN be
 *              turned off via Log_Config__mdt).
 *
 *              v2 changes:
 *              • Status__c uses consolidated uppercase values (ASSIGNED, NO_MATCH,
 *                CAPABILITY_MISMATCH, CAPACITY_EXCEEDED, LOCK_CONTENTION,
 *                RETRY_EXHAUSTED, FAILED)
 *              • Outcome__c field removed — single Status__c is authoritative
 *
 *              Governor cost: 1 DML per flush (bulk insert). Zero SOQL.
 *
 * @group Worker
 */
public with sharing class AuditLogger {

    private static final String CLS = 'AuditLogger';

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

        log.Query_Bind_Snapshot__c = sanitizeBindSnapshot(spec);

        Logger.debug('Audit entry created | config=' + bundle.developerName
                + ' | status=' + outcome.status
                + ' | recordId=' + outcome.recordId)
            .category(Logger.Category.AUDIT)
            .inClass(CLS).inMethod('createEntry')
            .forConfig(bundle.developerName)
            .forObject(bundle.objectApiName)
            .log();

        return new AuditEntry(log);
    }

    /**
     * @description Bulk-inserts all buffered audit entries in a single DML operation.
     *              Returns the list of inserted Routing_Log__c Ids (null for failures).
     *
     * @param entries AuditEntry list collected during bundle processing
     * @return List of Routing_Log__c Ids (same order as input)
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

        List<Database.SaveResult> results = Database.insert(
            logs,
            false,
            AccessLevel.USER_MODE
        );

        Integer successCount = 0;
        Integer failCount    = 0;

        for (Integer i = 0; i < results.size(); i++) {
            Database.SaveResult sr = results[i];
            if (sr.isSuccess()) {
                logIds.add(sr.getId());
                successCount++;
            } else {
                logIds.add(null);
                failCount++;
                String errMsg = formatErrors(sr.getErrors());
                Logger.error('Audit insert failed | config='
                        + logs[i].Config_Developer_Name__c
                        + ' | errors=' + errMsg)
                    .category(Logger.Category.AUDIT)
                    .inClass(CLS).inMethod('flush')
                    .log();
            }
        }

        Logger.info('Audit flush complete | inserted=' + successCount
                + ' | failed=' + failCount)
            .category(Logger.Category.AUDIT)
            .inClass(CLS).inMethod('flush')
            .withLimits()
            .log();

        return logIds;
    }

    // ─── Private Helpers ──────────────────────────────────────────────────────

    /**
     * @description Builds a PII-safe JSON snapshot of bind variable metadata.
     *              Stores bind KEY names and the SIZE of each list — never raw values.
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
