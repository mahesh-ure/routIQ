/**
 * @description Provides bounded retry logic for pessimistic row lock contention
 *              (UNABLE_TO_LOCK_ROW) during record assignment.
 *
 *              In the pull model, multiple agents may simultaneously request the
 *              next record. SELECT … FOR UPDATE can fail when two agents target the
 *              same candidate. This handler retries a lock-acquiring operation up to
 *              MAX_RETRIES times, giving concurrent transactions time to complete.
 *
 *              Cost: 0 SOQL / 0 DML — delegates to AssignmentSelector.lockRecord().
 *
 * @group Worker
 */
public with sharing class RetryLockHandler {

    private static final String CLS = 'RetryLockHandler';

    @TestVisible
    private static final Integer MAX_RETRIES = 5;

    // ─── Inner Value Object ───────────────────────────────────────────────────

    public class RetryOutcome {
        public SObject lockedRecord { get; private set; }
        public Boolean success      { get; private set; }
        public Integer retryCount   { get; private set; }
        public Boolean exhausted    { get; private set; }
        public String  errorMessage { get; private set; }

        @TestVisible
        private RetryOutcome() {}
    }

    // ─── RetryOutcome Factories ─────────────────────────────────────────────

    private static RetryOutcome outcomeLocked(SObject record, Integer retries) {
        RetryOutcome o = new RetryOutcome();
        o.lockedRecord = record;
        o.success = true;
        o.retryCount = retries;
        o.exhausted = false;
        return o;
    }

    private static RetryOutcome outcomeRecordGone(Integer retries) {
        RetryOutcome o = new RetryOutcome();
        o.success = false;
        o.retryCount = retries;
        o.exhausted = false;
        o.errorMessage = 'Record no longer exists or is not visible to the running user.';
        return o;
    }

    private static RetryOutcome outcomeExhausted(Integer retries) {
        RetryOutcome o = new RetryOutcome();
        o.success = false;
        o.retryCount = retries;
        o.exhausted = true;
        o.errorMessage = 'Lock contention: exhausted ' + retries + ' retry attempts.';
        return o;
    }

    // ─── Public API ───────────────────────────────────────────────────────────

    public static RetryOutcome attemptLock(
        String objectApiName,
        String ownerFieldApiName,
        Id recordId
    ) {
        Integer attempts = 0;

        while (attempts < MAX_RETRIES) {
            attempts++;

            try {
                SObject locked = AssignmentSelector.lockRecord(
                    objectApiName, ownerFieldApiName, recordId
                );

                if (locked == null) {
                    URE_Logger.warn('Record vanished before lock | object='
                            + objectApiName + ' | Id=' + recordId
                            + ' | attempt=' + attempts)
                        .category(URE_Logger.Category.LOCK)
                        .inClass(CLS).inMethod('attemptLock')
                        .forObject(objectApiName)
                        .forRecord(recordId)
                        .log();
                    return outcomeRecordGone(attempts);
                }

                if (attempts > 1) {
                    URE_Logger.info('Lock acquired after ' + attempts + ' attempts'
                            + ' | object=' + objectApiName + ' | Id=' + recordId)
                        .category(URE_Logger.Category.LOCK)
                        .inClass(CLS).inMethod('attemptLock')
                        .forObject(objectApiName)
                        .forRecord(recordId)
                        .log();
                }

                return outcomeLocked(locked, attempts);

            } catch (QueryException qe) {
                URE_Logger.warn('Lock contention | object=' + objectApiName
                        + ' | Id=' + recordId
                        + ' | attempt=' + attempts + '/' + MAX_RETRIES)
                    .category(URE_Logger.Category.LOCK)
                    .inClass(CLS).inMethod('attemptLock')
                    .forObject(objectApiName)
                    .forRecord(recordId)
                    .log();
            }
        }

        // All retries exhausted
        URE_Logger.error('Lock retries exhausted | object=' + objectApiName
                + ' | Id=' + recordId + ' | attempts=' + attempts)
            .category(URE_Logger.Category.LOCK)
            .inClass(CLS).inMethod('attemptLock')
            .forObject(objectApiName)
            .forRecord(recordId)
            .log();

        return outcomeExhausted(attempts);
    }

    public static RetryOutcome lockFirstAvailable(
        String objectApiName,
        String ownerFieldApiName,
        List<SObject> candidates
    ) {
        if (candidates == null || candidates.isEmpty()) {
            return outcomeExhausted(0);
        }

        Integer totalAttempts = 0;

        for (SObject candidate : candidates) {
            RetryOutcome outcome = attemptLock(
                objectApiName, ownerFieldApiName, candidate.Id
            );
            totalAttempts += outcome.retryCount;

            if (outcome.success) {
                return outcomeLocked(outcome.lockedRecord, totalAttempts);
            }

            URE_Logger.info('Skipping candidate ' + candidate.Id
                    + ' | reason: ' + outcome.errorMessage)
                .category(URE_Logger.Category.LOCK)
                .inClass(CLS).inMethod('lockFirstAvailable')
                .forObject(objectApiName)
                .forRecord(candidate.Id)
                .log();
        }

        return outcomeExhausted(totalAttempts);
    }
}
