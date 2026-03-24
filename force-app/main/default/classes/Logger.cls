/**
 * Logger
 * ─────────────────────────────────────────────────────────────────────────────
 * Transaction-scoped singleton logging framework for routIQ — Universal
 * Routing Engine (URE).
 *
 * DESIGN GOALS
 *   - Zero SOQL in the hot path.  All logging is buffered in a static List.
 *   - Two DML statements at flush time — one for the Log__c header,
 *     one bulk insert for all Log_Entry__c records.
 *   - Fluent builder API — readable call sites in every engine class.
 *   - Configurable via Log_Config__mdt — zero deployment to change
 *     log level or disable logging entirely.
 *   - Governor-aware — automatic WARN when any limit exceeds threshold.
 *   - Level-gated string work — message strings are only evaluated after
 *     the level check passes, preventing unnecessary CPU on disabled levels.
 *
 * GOVERNOR LIMIT BUDGET (this class adds to the existing URE budget)
 *   SOQL          +0  (CMDT reads are platform-cached; no dynamic SOQL here)
 *   DML           +2  (1 log header insert + 1 entries bulk insert)
 *   Heap          buffered entries x ~500B avg. MAX_BUFFER_ENTRIES caps this.
 *   CPU           Negligible — Limits.* calls + list operations only.
 *
 * TOTAL URE DML BUDGET after this class:
 *   1 (assignment update) + 1 (Routing_Log__c bulk insert)
 *   + 1 (Log__c header) + 1 (Log_Entry__c bulk insert) = 4 DML
 *   Well within the 150-statement limit.
 *
 * INTEGRATION POINTS (where callers should call Logger)
 *   RoutingService.execute()         -> Logger.init() then Logger.flush()
 *   ConfigLoader.load()              -> info / debug entries
 *   ConditionBinder.resolveAll()     -> debug entries per condition
 *   DynamicQueryBuilder.build()      -> debug with query structure (no values)
 *   CandidateSelector.query()        -> info with candidate count + limits
 *   RetryLockHandler.attemptAssignment() -> warn per retry, error on exhaustion
 *   AssignmentResolver.assign()      -> info on success, error on failure
 *   AuditLogger.logBulk()            -> info entry count
 *   RoutingEngine.execute()          -> perf snapshots between phases
 *
 * Namespace: ure
 * API Version: 65.0
 * Author: routIQ Engineering — CTA-reviewed
 * ─────────────────────────────────────────────────────────────────────────────
 */
public without sharing class Logger {

    // ─── Version ──────────────────────────────────────────────────────────────
    public static final String FRAMEWORK_VERSION = '1.0.0';

    // ─── Safety Caps ──────────────────────────────────────────────────────────

    /**
     * Hard cap on buffered entries per transaction.
     * Prevents runaway logging from blowing the heap limit.
     * When the buffer is full, new entries are silently dropped —
     * the logger never throws; it degrades gracefully.
     * Configurable via Log_Config__mdt.Max_Buffer_Entries__c.
     */
    @TestVisible
    private static Integer MAX_BUFFER_ENTRIES = 500;

    /**
     * Auto-emit a WARN entry when any governor limit reaches this percentage.
     * Configurable via Log_Config__mdt.Gov_Warn_Threshold_Pct__c.
     */
    @TestVisible
    private static Decimal GOV_WARN_THRESHOLD_PCT = 70.0;

    // ─── Log Level Enum ───────────────────────────────────────────────────────

    /**
     * Log levels in ascending severity order.
     * PERF is special — always logged when logging is enabled, regardless of
     * minimum level — ensures performance snapshots are never suppressed.
     *
     * Mapping:
     *   DEBUG  — Low-level engine internals (bind variable keys, SOQL fragments).
     *            Disabled in production via CMDT minimum level.
     *   INFO   — Normal routing events (config loaded, candidate found, assigned).
     *            Default production level.
     *   WARN   — Unexpected but recoverable (lock retry, unindexed field,
     *            approaching governor limit, empty bind list).
     *   ERROR  — Operation failed — a routing attempt did not complete
     *            (no candidates, assignment DML failed, exception caught).
     *   FATAL  — Transaction-level failure — something that should never happen
     *            in a healthy org (unexpected exception, CMDT corrupt).
     *   PERF   — Governor limit snapshot at a named phase boundary.
     *            Always recorded. Used to build the timing/limits story in logs.
     */
    public enum Level { DEBUG, INFO, WARN, ERROR, FATAL, PERF }

    // ─── Log Category Enum ────────────────────────────────────────────────────

    /**
     * Routing engine phase that generated this entry.
     * Allows filtering log entries by phase in the Log_Entry__c list view
     * without parsing message text.
     */
    public enum Category {
        ENGINE,           // Logger lifecycle (init, flush, config load)
        CONFIG,           // ConfigLoader — CMDT reads and bundle assembly
        CONDITION_BIND,   // ConditionBinder — STATIC value resolution (v2: USER_ATTRIBUTE removed)
        QUERY_BUILD,      // DynamicQueryBuilder — SOQL string assembly
        CANDIDATE,        // CandidateSelector — execution + result set analysis
        LOCK,             // RetryLockHandler — FOR UPDATE attempts and outcomes
        ASSIGNMENT,       // AssignmentResolver — owner field write
        AUDIT,            // AuditLogger — Routing_Log__c DML
        PERFORMANCE,      // Explicit governor limit snapshots between phases
        VALIDATION,       // Input validation, schema checks, config warnings
        SECURITY          // FLS/CRUD signals, USER_MODE enforcement
    }

    // ─── Static Transaction State ─────────────────────────────────────────────
    // All static — lives for the duration of one Apex transaction.

    @TestVisible private static Boolean           isInitialized   = false;
    @TestVisible private static Boolean           isEnabled       = true;
    @TestVisible private static Level             minimumLevel    = Level.DEBUG;
    @TestVisible private static Boolean           capturePerEntry = false;

    private static Long              txStartMs;
    @TestVisible private static String transactionId;
    private static Id                runningUserId;
    private static String            entryPoint;

    @TestVisible private static List<EntryBuffer> buffer          = new List<EntryBuffer>();
    private static Integer           seqCounter      = 0;
    private static Integer           errorCount      = 0;
    private static Integer           warnCount       = 0;
    private static Set<String>       configsInvoked  = new Set<String>();
    private static Set<String>       objectsRouted   = new Set<String>();

    // ─── Internal Buffer ──────────────────────────────────────────────────────

    /**
     * Pure in-memory record — never written to the database until flush().
     * Fields are deliberately not @AuraEnabled or @InvocableVariable —
     * this object is internal only.
     */
    @TestVisible
    private class EntryBuffer {
        Level    level;
        Category category;
        String   message;
        String   className;
        String   methodName;
        String   configDevName;
        String   objectApiName;
        String   recordId;
        String   exceptionType;
        String   exceptionMessage;
        String   stackTrace;
        String   govSnapshot;       // populated when capturePerEntry=true or PERF
        String   payloadJson;       // sanitised JSON — never raw user data
        Long     elapsedMs;
        Integer  sequence;
        Datetime entryTime;

        // Cheap point-in-time reads — no JSON, stored as raw numbers
        Integer  soqlAtPoint;
        Integer  dmlAtPoint;
        Long     cpuAtPoint;
        Long     heapAtPoint;
    }

    // ─── Fluent Builder ───────────────────────────────────────────────────────

    /**
     * Fluent builder returned by every log-level entry point.
     *
     * USAGE PATTERN:
     *   Logger.info('Candidates returned: ' + count)
     *       .category(Category.CANDIDATE)
     *       .inClass('CandidateSelector')
     *       .inMethod('query')
     *       .forConfig(configDevName)
     *       .forObject(objectApiName)
     *       .withLimits()
     *       .log();  <- terminal call — commits to buffer
     *
     * The builder is a NO-OP when:
     *   - Logger is not initialised (init() was never called).
     *   - Logging is disabled via CMDT.
     *   - The entry level is below minimumLevel.
     * No exceptions are thrown in any of these cases.
     */
    public class Builder {

        private EntryBuffer rec;
        private Boolean     active;     // false = no-op mode

        @TestVisible
        Builder(Level lvl, String msg) {
            active = isInitialized && isEnabled && levelPasses(lvl);
            if (!active) return;

            rec                = new EntryBuffer();
            rec.level          = lvl;
            rec.message        = truncate(msg, 4000);
            rec.category       = Category.ENGINE;
            rec.entryTime      = System.now();
            rec.elapsedMs      = txStartMs == null ? 0L
                                 : (System.currentTimeMillis() - txStartMs);
            rec.sequence       = ++seqCounter;

            // Cheap limit reads — no JSON serialisation
            rec.soqlAtPoint    = Limits.getQueries();
            rec.dmlAtPoint     = Limits.getDmlStatements();
            rec.cpuAtPoint     = Limits.getCpuTime();
            rec.heapAtPoint    = Limits.getHeapSize();

            // Full snapshot only when configured or PERF level
            if (capturePerEntry || lvl == Level.PERF) {
                rec.govSnapshot = GovLimits.capture().toCompactDisplay();
            }
        }

        // ── Context Setters ────────────────────────────────────────────────

        /** Which engine phase generated this entry. */
        public Builder category(Category cat) {
            if (active) rec.category = cat;
            return this;
        }

        /** Apex class that generated this entry. */
        public Builder inClass(String cls) {
            if (active) rec.className = cls;
            return this;
        }

        /** Method name within the class. */
        public Builder inMethod(String mth) {
            if (active) rec.methodName = mth;
            return this;
        }

        /**
         * Routing config this entry relates to.
         * Also registers the config name for the transaction-level summary.
         */
        public Builder forConfig(String cfg) {
            if (active && String.isNotBlank(cfg)) {
                rec.configDevName = cfg;
                configsInvoked.add(cfg);
            }
            return this;
        }

        /**
         * SObject API name being routed.
         * Also registers the object name for the transaction-level summary.
         */
        public Builder forObject(String obj) {
            if (active && String.isNotBlank(obj)) {
                rec.objectApiName = obj;
                objectsRouted.add(obj);
            }
            return this;
        }

        /** Record Id being routed. */
        public Builder forRecord(Id rid) {
            if (active && rid != null) rec.recordId = String.valueOf(rid);
            return this;
        }

        /**
         * Attach exception details.
         * Captures type, message, and stack trace.
         * Never re-throws.
         */
        public Builder withException(Exception e) {
            if (active && e != null) {
                rec.exceptionType    = e.getTypeName();
                rec.exceptionMessage = truncate(e.getMessage(), 4000);
                rec.stackTrace       = truncate(e.getStackTraceString(), 32768);
            }
            return this;
        }

        /**
         * Attach a sanitised JSON payload for debugging context.
         * Only call with data that contains NO PII — bind variable keys
         * and sizes are safe; actual field values from User or record are not.
         */
        public Builder withPayload(Object payload) {
            if (active && payload != null) {
                try {
                    rec.payloadJson = truncate(JSON.serialize(payload), 32768);
                } catch (Exception e) {
                    rec.payloadJson = '{"error":"serialisation failed"}';
                }
            }
            return this;
        }

        /**
         * Explicitly capture a full governor limit snapshot at this point.
         * Use at key phase boundaries even when capturePerEntry = false.
         * Always used automatically for PERF-level entries.
         */
        public Builder withLimits() {
            if (active) rec.govSnapshot = GovLimits.capture().toCompactDisplay();
            return this;
        }

        /**
         * Terminal call — commits the entry to the static buffer.
         * Nothing is written to the database here. DML happens only in flush().
         *
         * If the buffer is full (MAX_BUFFER_ENTRIES), the entry is silently
         * dropped — the logger never throws or affects the routing transaction.
         */
        public void log() {
            if (!active) return;
            if (buffer.size() >= MAX_BUFFER_ENTRIES) return; // safety valve

            // Update transaction-level counters
            if (rec.level == Level.ERROR || rec.level == Level.FATAL) errorCount++;
            if (rec.level == Level.WARN)  warnCount++;

            buffer.add(rec);
        }
    }

    // ─── Initialisation ───────────────────────────────────────────────────────

    /**
     * Initialise the logger for a new routing transaction.
     *
     * MUST be called once at the start of RoutingService.execute().
     * Idempotent — safe to call multiple times in the same transaction;
     * subsequent calls are ignored.
     *
     * Reads Log_Config__mdt via CMDT.getAll() — zero SOQL.
     *
     * @param ep      Entry point label (InvocableMethod / REST / LWC / GlobalAction)
     * @param userId  Id of the agent making the routing request
     */
    public static void init(String ep, Id userId) {
        if (isInitialized) return;   // idempotent

        loadConfig();                // reads CMDT — zero SOQL
        if (!isEnabled) return;

        entryPoint      = ep;
        runningUserId   = userId;
        transactionId   = generateTransactionId();
        txStartMs       = System.currentTimeMillis();
        buffer          = new List<EntryBuffer>();
        seqCounter      = 0;
        errorCount      = 0;
        warnCount       = 0;
        configsInvoked  = new Set<String>();
        objectsRouted   = new Set<String>();
        isInitialized   = true;
    }

    // ─── Log-Level Entry Points ───────────────────────────────────────────────

    /**
     * Engine internals — bind variable keys, SOQL fragment assembly,
     * per-condition processing. Disable in production via CMDT minimum level.
     */
    public static Builder debug(String msg) { return new Builder(Level.DEBUG, msg); }

    /**
     * Normal routing events — config loaded, candidate found, assignment
     * succeeded, audit record written.
     */
    public static Builder info(String msg)  { return new Builder(Level.INFO,  msg); }

    /**
     * Unexpected but recoverable — lock retry, empty user attribute list,
     * unindexed field, approaching governor limit.
     */
    public static Builder warn(String msg)  { return new Builder(Level.WARN,  msg); }

    /**
     * Operation failed — no candidates found, assignment DML failed,
     * retry exhausted, caught exception.
     */
    public static Builder error(String msg) { return new Builder(Level.ERROR, msg); }

    /**
     * Transaction-level failure — something that should never happen in a
     * healthy org. Used for unexpected exceptions that escape the engine loop.
     */
    public static Builder fatal(String msg) { return new Builder(Level.FATAL, msg); }

    /**
     * Governor limit snapshot at a named phase boundary.
     * Always recorded regardless of minimumLevel.
     * Use at: after config load, after user SOQL, after candidate query,
     * after assignment DML, before flush.
     */
    public static Builder perf(String msg)  { return new Builder(Level.PERF,  msg); }

    // ─── Flush ────────────────────────────────────────────────────────────────

    /**
     * Write all buffered entries to the database.
     *
     * Call once at the very end of RoutingService.execute(), AFTER
     * AuditLogger.logBulk() has already inserted Routing_Log__c records.
     * This keeps the Logger DML budget isolated from the routing DML.
     *
     * DML cost: 1 (Log__c insert) + 1 (Log_Entry__c bulk insert) = 2.
     *
     * Returns the inserted Log__c record (for test assertions).
     * Returns null if logging is disabled.
     *
     * @param  finalStatus  The overall routing outcome:
     *                      Success / Failure / No_Match / Retry_Exhausted /
     *                      Lock_Contention / Partial
     * @return Log__c  The inserted log header, or null.
     */
    public static Log__c flush(String finalStatus) {
        if (!isInitialized || !isEnabled) return null;

        Long endMs = System.currentTimeMillis();
        if (txStartMs == null)      txStartMs     = endMs;
        if (transactionId == null)  transactionId  = generateTransactionId();
        if (entryPoint == null)     entryPoint     = 'Test';

        // Take a final snapshot BEFORE our own DML adds to the counters
        GovLimits finalLimits = GovLimits.capture();

        // Auto-warn if any limit is approaching the threshold
        if (finalLimits.isApproachingLimit(GOV_WARN_THRESHOLD_PCT)) {
            warn('Governor limit approaching threshold ('
                 + GOV_WARN_THRESHOLD_PCT + '%) — '
                 + finalLimits.toCompactDisplay())
                .category(Category.PERFORMANCE)
                .inClass('Logger')
                .inMethod('flush')
                .log();
        }

        // Final summary entry
        info('Transaction complete | status='   + finalStatus
             + ' | entries='    + buffer.size()
             + ' | errors='     + errorCount
             + ' | warnings='   + warnCount
             + ' | durationMs=' + (endMs - txStartMs)
             + ' | configs=['   + String.join(new List<String>(configsInvoked), ',') + ']'
             + ' | objects=['   + String.join(new List<String>(objectsRouted),  ',') + ']'
             + ' | '            + finalLimits.toCompactDisplay())
            .category(Category.ENGINE)
            .inClass('Logger')
            .inMethod('flush')
            .log();

        // ── Build and insert log header ────────────────────────────────────
        Log__c logHeader = new Log__c(
            Transaction_Id__c     = transactionId,
            Entry_Point__c        = entryPoint,
            User__c               = runningUserId,
            Start_Time__c         = Datetime.newInstance(txStartMs),
            End_Time__c           = Datetime.newInstance(endMs),
            Duration_Ms__c        = endMs - txStartMs,
            Status__c             = finalStatus,
            Has_Errors__c         = errorCount > 0,
            Has_Warnings__c       = warnCount  > 0,
            Error_Count__c        = errorCount,
            Warn_Count__c         = warnCount,
            Total_Entries__c      = buffer.size(),
            Configs_Invoked__c    = String.join(new List<String>(configsInvoked), ', '),
            Objects_Routed__c     = String.join(new List<String>(objectsRouted),  ', '),
            Gov_Limits_Final__c   = finalLimits.toCompactDisplay(),
            Gov_Limits_Json__c    = finalLimits.toJson(),
            Soql_Used__c          = finalLimits.soqlUsed,
            Dml_Used__c           = finalLimits.dmlStmtsUsed,
            Cpu_Used_Ms__c        = finalLimits.cpuUsedMs,
            Heap_Used_Kb__c       = finalLimits.heapUsedBytes / 1024,
            Soql_Pct__c           = finalLimits.soqlPct,
            Cpu_Pct__c            = finalLimits.cpuPct,
            Heap_Pct__c           = finalLimits.heapPct,
            Framework_Version__c  = FRAMEWORK_VERSION
        );

        insert logHeader; // DML statement 1

        // ── Build and bulk-insert entries ─────────────────────────────────
        List<Log_Entry__c> entries = new List<Log_Entry__c>();

        for (EntryBuffer b : buffer) {
            entries.add(new Log_Entry__c(
                Log__c                 = logHeader.Id,
                Sequence__c            = b.sequence,
                Timestamp__c           = b.entryTime,
                Elapsed_Ms__c          = b.elapsedMs,
                Level__c               = b.level.name(),
                Category__c            = b.category.name(),
                Message__c             = b.message,
                Class_Name__c          = b.className,
                Method_Name__c         = b.methodName,
                Config_Dev_Name__c     = b.configDevName,
                Object_Api_Name__c     = b.objectApiName,
                Record_Id__c           = b.recordId,
                Exception_Type__c      = b.exceptionType,
                Exception_Message__c   = b.exceptionMessage,
                Stack_Trace__c         = b.stackTrace,
                Gov_Limits_At_Point__c = b.govSnapshot,
                Soql_At_Point__c       = b.soqlAtPoint,
                Dml_At_Point__c        = b.dmlAtPoint,
                Cpu_At_Point_Ms__c     = b.cpuAtPoint,
                Heap_At_Point_Kb__c    = b.heapAtPoint == null ? null : b.heapAtPoint / 1024,
                Payload__c             = b.payloadJson
            ));
        }

        if (!entries.isEmpty()) {
            insert entries; // DML statement 2 — bulk, one statement regardless of count
        }

        Log__c result = logHeader;
        reset(); // clear static state
        return result;
    }

    // ─── Private Helpers ─────────────────────────────────────────────────────

    /**
     * Load framework configuration from Log_Config__mdt.
     * CMDT.getAll() is zero SOQL — platform-cached.
     * Falls back to safe defaults if no record exists.
     */
    private static void loadConfig() {
        Map<String, Log_Config__mdt> configs =
            Log_Config__mdt.getAll();

        Log_Config__mdt cfg = configs.get('Default');
        if (cfg == null) return; // use class-level defaults

        isEnabled       = cfg.Is_Enabled__c;
        capturePerEntry = cfg.Capture_Gov_Limits_Per_Entry__c;

        if (cfg.Gov_Warn_Threshold_Pct__c != null) {
            GOV_WARN_THRESHOLD_PCT = cfg.Gov_Warn_Threshold_Pct__c;
        }

        if (cfg.Max_Buffer_Entries__c != null) {
            MAX_BUFFER_ENTRIES = cfg.Max_Buffer_Entries__c.intValue();
        }

        String lvl = cfg.Minimum_Level__c;
        if (String.isNotBlank(lvl)) {
            try {
                minimumLevel = Level.valueOf(lvl);
            } catch (Exception ignored) {
                minimumLevel = Level.DEBUG;
            }
        }
    }

    /**
     * True if the given level is at or above minimumLevel.
     * PERF always passes — it is never suppressed.
     */
    private static Boolean levelPasses(Level lvl) {
        if (lvl == Level.PERF) return true;
        // Enum ordinal ordering: DEBUG=0 INFO=1 WARN=2 ERROR=3 FATAL=4
        return lvl.ordinal() >= minimumLevel.ordinal();
    }

    /**
     * Generate a UUID-v4-style transaction identifier.
     * Uses Crypto.generateAesKey() — cryptographically random, no SOQL.
     * Format: 8-4-4-4-12 hex characters.
     */
    private static String generateTransactionId() {
        String hex = EncodingUtil.convertToHex(Crypto.generateAesKey(128));
        return hex.substring(0,  8)  + '-'
             + hex.substring(8,  12) + '-'
             + hex.substring(12, 16) + '-'
             + hex.substring(16, 20) + '-'
             + hex.substring(20, 32);
    }

    /**
     * Truncate a string to maxLen characters.
     * Prevents heap explosion from very long exception stack traces.
     */
    private static String truncate(String s, Integer maxLen) {
        if (s == null)              return null;
        if (s.length() <= maxLen)   return s;
        return s.substring(0, maxLen - 3) + '...';
    }

    /**
     * Reset all static state.
     * Called at the end of flush() so the logger is clean if the transaction
     * somehow invokes another routing operation (e.g. recursive flow trigger).
     */
    @TestVisible
    private static void reset() {
        isInitialized  = false;
        buffer         = new List<EntryBuffer>();
        seqCounter     = 0;
        errorCount     = 0;
        warnCount      = 0;
        configsInvoked = new Set<String>();
        objectsRouted  = new Set<String>();
        txStartMs      = null;
        transactionId  = null;
        entryPoint     = null;
    }

    /** Transaction Id accessor for merged log entries. */
    public static String getTransactionId() { return transactionId; }

    /** Buffer size accessor for test assertions. */
    @TestVisible
    private static Integer getBufferSize() { return buffer.size(); }

    /** Error count accessor for test assertions. */
    @TestVisible
    private static Integer getErrorCount()  { return errorCount; }

    /** Warn count accessor for test assertions. */
    @TestVisible
    private static Integer getWarnCount()   { return warnCount; }
}
