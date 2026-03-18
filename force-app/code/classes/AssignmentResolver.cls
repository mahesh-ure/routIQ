/**
 * @description Orchestrates the record assignment phase of routing: locks a candidate
 *              record, updates its owner field, and returns the outcome.
 *
 *              Flow (per ConfigBundle):
 *              1. Check Allow_Multiple__c — if false and agent already owns a record
 *                 for this object/owner-field combination, skip assignment.
 *              2. Lock first available candidate via RetryLockHandler.lockFirstAvailable().
 *              3. Update the owner field on the locked record.
 *              4. Return a structured AssignmentOutcome for downstream logging and
 *                 RoutingResult construction.
 *
 *              Security:
 *              • DML uses AccessLevel.USER_MODE — respects CRUD/FLS.
 *              • All SOQL is delegated to AssignmentSelector (bind-variable only, USER_MODE).
 *              • Owner field name originates from CMDT (admin-controlled).
 *
 *              Governor awareness:
 *              • 1 DML (update) on success. 0 DML on failure / no-match / contention.
 *              • SOQL cost is bounded by RetryLockHandler (MAX_RETRIES × candidates tried).
 *              • No DML in loops — single record update per assignment.
 *
 * @group Worker
 */
public with sharing class AssignmentResolver {

    // ─── Inner Value Object ───────────────────────────────────────────────────

    /**
     * @description Structured outcome of an assignment attempt. Consumed by
     *              RoutingEngine to build RoutingResult and Routing_Log__c.
     *              Factory methods live on the outer class because Apex does not
     *              allow static methods on inner classes.
     */
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

    // ─── AssignmentOutcome Factories (outer-class statics) ────────────────────

    /**
     * @description Creates outcome for a successful assignment.
     */
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

    /**
     * @description Creates outcome when no candidates exist.
     */
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

    /**
     * @description Creates outcome when agent already owns a record
     *              and Allow_Multiple__c is false.
     */
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

    /**
     * @description Creates outcome when all lock retries are exhausted.
     */
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

    /**
     * @description Creates outcome when DML update of the owner field fails.
     */
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

    /**
     * @description Creates a generic failure outcome for engine-level exceptions
     *              that occur outside the normal assignment flow (e.g. malformed SOQL,
     *              unexpected exception during condition binding or query building).
     *
     *              Public so RoutingEngine can create audit-loggable outcomes for
     *              any bundle that throws an unexpected exception.
     *
     * @param errorMessage Description of the failure
     * @return Failure outcome with status 'Failed'
     */
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

    /**
     * @description Resolves assignment for a single ConfigBundle: checks existing
     *              assignments, locks a candidate, updates ownership.
     *
     * @param bundle      The routing config bundle
     * @param candidates  Priority-sorted candidate records from CandidateSelector
     * @param agentUserId The agent requesting work (pull model)
     * @return AssignmentOutcome describing the result
     */
    public static AssignmentOutcome resolve(
        ConfigBundle bundle,
        List<SObject> candidates,
        Id agentUserId
    ) {
        // ─── Guard: no candidates ─────────────────────────────────────────
        if (candidates == null || candidates.isEmpty()) {
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
                false,              // allOrNone = false — capture errors gracefully
                AccessLevel.USER_MODE
            );

            if (!sr.isSuccess()) {
                String dmlErrors = formatDmlErrors(sr.getErrors());
                System.debug(LoggingLevel.ERROR,
                    'AssignmentResolver: DML failed for ' + bundle.objectApiName
                    + ' Id=' + lockedRecord.Id + ': ' + dmlErrors);
                return outcomeDmlFailure(
                    lockedRecord.Id,
                    dmlErrors,
                    lockOutcome.retryCount,
                    candidateCount
                );
            }

            return outcomeAssigned(
                lockedRecord.Id,
                lockOutcome.retryCount,
                candidateCount
            );

        } catch (DmlException dmlEx) {
            // Catch unexpected DmlException (e.g. trigger validation rule)
            System.debug(LoggingLevel.ERROR,
                'AssignmentResolver: DmlException for ' + bundle.objectApiName
                + ' Id=' + lockedRecord.Id + ': ' + dmlEx.getMessage());
            return outcomeDmlFailure(
                lockedRecord.Id,
                dmlEx.getMessage(),
                lockOutcome.retryCount,
                candidateCount
            );
        }
    }

    // ─── Private Helpers ──────────────────────────────────────────────────────

    /**
     * @description Formats Database.Error list into a single human-readable string
     *              for error messages and audit logging.
     */
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
