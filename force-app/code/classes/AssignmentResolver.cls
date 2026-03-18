/**
 * @description Orchestrates the record assignment phase of routing: locks a candidate
 *              record, updates its owner field, and returns the outcome.
 *
 *              Security:
 *              • DML uses AccessLevel.USER_MODE — respects CRUD/FLS.
 *              • All SOQL is delegated to AssignmentSelector (bind-variable only, USER_MODE).
 *
 *              Governor awareness:
 *              • 1 DML (update) on success. 0 DML on failure / no-match / contention.
 *              • SOQL cost is bounded by RetryLockHandler (MAX_RETRIES × candidates tried).
 *
 * @group Worker
 */
public with sharing class AssignmentResolver {

    private static final String CLS = 'AssignmentResolver';

    // ─── Inner Value Object ───────────────────────────────────────────────────

    public class AssignmentOutcome {
        public Id      recordId       { get; private set; }
        public Boolean success        { get; private set; }
        public Boolean lockContention { get; private set; }
        public Integer retryCount     { get; private set; }
        public Integer candidateCount { get; private set; }
        public String  errorMessage   { get; private set; }
        public String  status         { get; private set; }

        @TestVisible
        private AssignmentOutcome() {}
    }

    // ─── AssignmentOutcome Factories ────────────────────────────────────────

    private static AssignmentOutcome outcomeAssigned(
        Id recordId,
        Integer retryCount,
        Integer candidateCount
    ) {
        AssignmentOutcome o = new AssignmentOutcome();
        o.recordId = recordId;
        o.success = true;
        o.lockContention = (retryCount > 1);
        o.retryCount = retryCount;
        o.candidateCount = candidateCount;
        o.status = 'Success';
        return o;
    }

    private static AssignmentOutcome outcomeNoMatch(Integer candidateCount) {
        AssignmentOutcome o = new AssignmentOutcome();
        o.success = false;
        o.lockContention = false;
        o.retryCount = 0;
        o.candidateCount = candidateCount;
        o.status = 'No_Match';
        o.errorMessage = 'No matching candidates found.';
        return o;
    }

    private static AssignmentOutcome outcomeAlreadyAssigned() {
        AssignmentOutcome o = new AssignmentOutcome();
        o.success = false;
        o.lockContention = false;
        o.retryCount = 0;
        o.candidateCount = 0;
        o.status = 'No_Match';
        o.errorMessage = 'Agent already has an active assignment (Allow_Multiple = false).';
        return o;
    }

    private static AssignmentOutcome outcomeLockExhausted(
        Integer retryCount,
        Integer candidateCount
    ) {
        AssignmentOutcome o = new AssignmentOutcome();
        o.success = false;
        o.lockContention = true;
        o.retryCount = retryCount;
        o.candidateCount = candidateCount;
        o.status = 'Retry_Exhausted';
        o.errorMessage = 'Lock contention: unable to acquire lock after '
            + retryCount + ' attempts across ' + candidateCount + ' candidates.';
        return o;
    }

    private static AssignmentOutcome outcomeDmlFailure(
        Id recordId,
        String errorMsg,
        Integer retryCount,
        Integer candidateCount
    ) {
        AssignmentOutcome o = new AssignmentOutcome();
        o.recordId = recordId;
        o.success = false;
        o.lockContention = false;
        o.retryCount = retryCount;
        o.candidateCount = candidateCount;
        o.status = 'Failed';
        o.errorMessage = errorMsg;
        return o;
    }

    public static AssignmentOutcome outcomeError(String errorMessage) {
        AssignmentOutcome o = new AssignmentOutcome();
        o.success = false;
        o.lockContention = false;
        o.retryCount = 0;
        o.candidateCount = 0;
        o.status = 'Failed';
        o.errorMessage = errorMessage;
        return o;
    }

    // ─── Public API ───────────────────────────────────────────────────────────

    public static AssignmentOutcome resolve(
        ConfigBundle bundle,
        List<SObject> candidates,
        Id agentUserId
    ) {
        // ─── Guard: no candidates ─────────────────────────────────────────
        if (candidates == null || candidates.isEmpty()) {
            URE_Logger.info('No candidates for assignment'
                    + ' | config=' + bundle.developerName)
                .category(URE_Logger.Category.ASSIGNMENT)
                .inClass(CLS).inMethod('resolve')
                .forConfig(bundle.developerName)
                .forObject(bundle.objectApiName)
                .log();
            return outcomeNoMatch(0);
        }

        Integer candidateCount = candidates.size();

        // ─── Guard: Allow_Multiple__c enforcement ─────────────────────────
        if (!bundle.allowMultiple) {
            List<SObject> existing = AssignmentSelector.queryOwnedRecords(
                bundle.objectApiName,
                bundle.ownerFieldApiName,
                agentUserId
            );
            if (!existing.isEmpty()) {
                URE_Logger.info('Agent already assigned (Allow_Multiple=false)'
                        + ' | config=' + bundle.developerName
                        + ' | agent=' + agentUserId)
                    .category(URE_Logger.Category.ASSIGNMENT)
                    .inClass(CLS).inMethod('resolve')
                    .forConfig(bundle.developerName)
                    .forObject(bundle.objectApiName)
                    .log();
                return outcomeAlreadyAssigned();
            }
        }

        // ─── Lock first available candidate ───────────────────────────────
        RetryLockHandler.RetryOutcome lockOutcome = RetryLockHandler.lockFirstAvailable(
            bundle.objectApiName,
            bundle.ownerFieldApiName,
            candidates
        );

        if (!lockOutcome.success) {
            URE_Logger.error('Lock exhausted for all candidates'
                    + ' | config=' + bundle.developerName
                    + ' | candidateCount=' + candidateCount
                    + ' | totalRetries=' + lockOutcome.retryCount)
                .category(URE_Logger.Category.ASSIGNMENT)
                .inClass(CLS).inMethod('resolve')
                .forConfig(bundle.developerName)
                .forObject(bundle.objectApiName)
                .log();
            return outcomeLockExhausted(
                lockOutcome.retryCount,
                candidateCount
            );
        }

        // ─── Update owner field ───────────────────────────────────────────
        SObject lockedRecord = lockOutcome.lockedRecord;

        try {
            lockedRecord.put(bundle.ownerFieldApiName, agentUserId);

            Database.SaveResult sr = Database.update(
                lockedRecord,
                false,
                AccessLevel.USER_MODE
            );

            if (!sr.isSuccess()) {
                String dmlErrors = formatDmlErrors(sr.getErrors());
                URE_Logger.error('Assignment DML failed | object=' + bundle.objectApiName
                        + ' | Id=' + lockedRecord.Id + ' | errors=' + dmlErrors)
                    .category(URE_Logger.Category.ASSIGNMENT)
                    .inClass(CLS).inMethod('resolve')
                    .forConfig(bundle.developerName)
                    .forObject(bundle.objectApiName)
                    .forRecord(lockedRecord.Id)
                    .log();
                return outcomeDmlFailure(
                    lockedRecord.Id,
                    dmlErrors,
                    lockOutcome.retryCount,
                    candidateCount
                );
            }

            URE_Logger.info('Assignment succeeded | object=' + bundle.objectApiName
                    + ' | recordId=' + lockedRecord.Id
                    + ' | agent=' + agentUserId
                    + ' | retries=' + lockOutcome.retryCount)
                .category(URE_Logger.Category.ASSIGNMENT)
                .inClass(CLS).inMethod('resolve')
                .forConfig(bundle.developerName)
                .forObject(bundle.objectApiName)
                .forRecord(lockedRecord.Id)
                .withLimits()
                .log();

            return outcomeAssigned(
                lockedRecord.Id,
                lockOutcome.retryCount,
                candidateCount
            );

        } catch (DmlException dmlEx) {
            URE_Logger.error('DmlException during assignment | object=' + bundle.objectApiName
                    + ' | Id=' + lockedRecord.Id)
                .category(URE_Logger.Category.ASSIGNMENT)
                .inClass(CLS).inMethod('resolve')
                .forConfig(bundle.developerName)
                .forObject(bundle.objectApiName)
                .forRecord(lockedRecord.Id)
                .withException(dmlEx)
                .log();
            return outcomeDmlFailure(
                lockedRecord.Id,
                dmlEx.getMessage(),
                lockOutcome.retryCount,
                candidateCount
            );
        }
    }

    // ─── Private Helpers ──────────────────────────────────────────────────────

    private static String formatDmlErrors(List<Database.Error> errors) {
        if (errors == null || errors.isEmpty()) {
            return 'Unknown DML error.';
        }
        List<String> messages = new List<String>();
        for (Database.Error err : errors) {
            messages.add(err.getStatusCode() + ': ' + err.getMessage());
        }
        return String.join(messages, '; ');
    }
}
