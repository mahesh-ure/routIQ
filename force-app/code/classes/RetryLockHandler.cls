/**
 * @description Provides bounded retry logic for pessimistic row lock contention
 *              (UNABLE_TO_LOCK_ROW) during record assignment.
 *
 *              In the pull model, multiple agents may simultaneously request the
 *              next record. SELECT … FOR UPDATE can fail when two agents target the
 *              same candidate. This handler retries a lock-acquiring operation up to
 *              maxRetries times, giving concurrent transactions time to complete.
 *
 *              v2 change: MAX_RETRIES is now admin-configurable via
 *              Routing_Config__mdt.Max_Retry_Attempts__c (default 1). The constant
 *              remains as a fallback when no config value is provided. Admin can
 *              increase for high-contention environments.
 *
 *              Design decisions:
 *              • Does NOT use Thread.sleep() — Apex doesn't support it and retries
 *                are immediate. The lock wait happens inside the SOQL FOR UPDATE
 *                itself (Salesforce waits ~5s per attempt before throwing).
 *              • Returns a structured RetryOutcome so callers get the locked record,
 *                success/failure, and retry count without try-catch boilerplate.
 *              • Lock contention is expected in high-concurrency routing — it is NOT
 *                an error condition, just a signal to try the next candidate.
 *
 *              Cost: 0 SOQL / 0 DML — delegates to AssignmentSelector.lockRecord().
 *
 * @group Worker
 */
public with sharing class RetryLockHandler {

    private static final String CLS = 'RetryLockHandler';

    /** Fallback when Config.Max_Retry_Attempts__c is not set. Default 1 in v2. */
    @TestVisible
    private static final Integer DEFAULT_MAX_RETRIES = 1;

    // ─── Inner Value Object ───────────────────────────────────────────────────

    /**
     * @description Outcome of a lock attempt with retry tracking.
     *              Factory methods live on the outer class because Apex does not
     *              allow static methods on inner classes.
     */
    public class RetryOutcome {
        public SObject lockedRecord { get; private set; }
        public Boolean success      { get; private set; }
        public Integer retryCount   { get; private set; }
        public Boolean exhausted    { get; private set; }
        public String  errorMessage { get; private set; }

        @TestVisible
        private RetryOutcome() {}
    }

    // ─── RetryOutcome Factories (outer-class statics) ─────────────────────────

    /**
     * @description Creates outcome for a successful lock acquisition.
     */
    private static RetryOutcome outcomeLocked(SObject record, Integer retries) {
        RetryOutcome o = new RetryOutcome();
        o.lockedRecord = record;
        o.success = true;
        o.retryCount = retries;
        o.exhausted = false;
        return o;
    }

    /**
     * @description Creates outcome when the record vanished between candidate query
     *              and lock attempt (deleted or no longer visible).
     */
    private static RetryOutcome outcomeRecordGone(Integer retries) {
        RetryOutcome o = new RetryOutcome();
        o.success = false;
        o.retryCount = retries;
        o.exhausted = false;
        o.errorMessage = 'Record no longer exists or is not visible to the running user.';
        return o;
    }

    /**
     * @description Creates outcome when all retry attempts are exhausted.
     */
    private static RetryOutcome outcomeExhausted(Integer retries) {
        RetryOutcome o = new RetryOutcome();
        o.success = false;
        o.retryCount = retries;
        o.exhausted = true;
        o.errorMessage = 'Lock contention: exhausted ' + retries + ' retry attempts.';
        return o;
    }

    // ─── Public API ───────────────────────────────────────────────────────────

    /**
     * @description Attempts to acquire a row lock on a single candidate record via
     *              AssignmentSelector.lockRecord(), retrying up to maxRetries times
     *              on UNABLE_TO_LOCK_ROW.
     *
     * @param objectApiName     SObject API name (from ConfigBundle)
     * @param ownerFieldApiName Owner field API name (from ConfigBundle)
     * @param recordId          Id of the candidate to lock
     * @param maxRetries        Max retry attempts (from ConfigBundle.maxRetryAttempts)
     * @return RetryOutcome with locked record on success, or failure details
     */
    public static RetryOutcome attemptLock(
        String objectApiName,
        String ownerFieldApiName,
        Id recordId,
        Integer maxRetries
    ) {
        Integer effectiveMax = (maxRetries != null && maxRetries > 0)
            ? maxRetries
            : DEFAULT_MAX_RETRIES;
        Integer attempts = 0;

        while (attempts < effectiveMax) {
            attempts++;

            try {
                SObject locked = AssignmentSelector.lockRecord(
                    objectApiName, ownerFieldApiName, recordId
                );

                if (locked == null) {
                    Logger.warn('Record vanished before lock | object='
                            + objectApiName + ' | Id=' + recordId
                            + ' | attempt=' + attempts)
                        .category(Logger.Category.LOCK)
                        .inClass(CLS).inMethod('attemptLock')
                        .forObject(objectApiName)
                        .forRecord(recordId)
                        .log();
                    return outcomeRecordGone(attempts);
                }

                return outcomeLocked(locked, attempts);

            } catch (QueryException qe) {
                Logger.warn('Lock contention | object=' + objectApiName
                        + ' | Id=' + recordId
                        + ' | attempt=' + attempts + '/' + effectiveMax)
                    .category(Logger.Category.LOCK)
                    .inClass(CLS).inMethod('attemptLock')
                    .forObject(objectApiName)
                    .forRecord(recordId)
                    .log();
            }
        }

        // All retries exhausted
        Logger.error('Lock retries exhausted | object=' + objectApiName
                + ' | Id=' + recordId + ' | attempts=' + attempts)
            .category(Logger.Category.LOCK)
            .inClass(CLS).inMethod('attemptLock')
            .forObject(objectApiName)
            .forRecord(recordId)
            .log();

        return outcomeExhausted(attempts);
    }

    /**
     * @description Backward-compatible overload using DEFAULT_MAX_RETRIES.
     */
    public static RetryOutcome attemptLock(
        String objectApiName,
        String ownerFieldApiName,
        Id recordId
    ) {
        return attemptLock(objectApiName, ownerFieldApiName, recordId, DEFAULT_MAX_RETRIES);
    }

    /**
     * @description Attempts to lock candidates from an ordered list, trying the next
     *              candidate when the current one fails all lock retries.
     *
     *              This is the primary method used by AssignmentResolver — it walks
     *              the priority-sorted candidate list and returns the first record
     *              that can be successfully locked.
     *
     * @param objectApiName     SObject API name
     * @param ownerFieldApiName Owner field API name
     * @param candidates        Priority-sorted candidate records from CandidateSelector
     * @param maxRetries        Max retry attempts per candidate
     * @return RetryOutcome for the first successfully locked candidate,
     *         or an exhausted outcome if no candidate could be locked
     */
    public static RetryOutcome lockFirstAvailable(
        String objectApiName,
        String ownerFieldApiName,
        List<SObject> candidates,
        Integer maxRetries
    ) {
        if (candidates == null || candidates.isEmpty()) {
            return outcomeExhausted(0);
        }

        Integer totalAttempts = 0;

        for (SObject candidate : candidates) {
            RetryOutcome outcome = attemptLock(
                objectApiName, ownerFieldApiName, candidate.Id, maxRetries
            );
            totalAttempts += outcome.retryCount;

            if (outcome.success) {
                return outcomeLocked(outcome.lockedRecord, totalAttempts);
            }
        }

        return outcomeExhausted(totalAttempts);
    }

    /**
     * @description Backward-compatible overload using DEFAULT_MAX_RETRIES.
     */
    public static RetryOutcome lockFirstAvailable(
        String objectApiName,
        String ownerFieldApiName,
        List<SObject> candidates
    ) {
        return lockFirstAvailable(objectApiName, ownerFieldApiName, candidates, DEFAULT_MAX_RETRIES);
    }
}
