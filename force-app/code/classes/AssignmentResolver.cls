/**
 * @description Orchestrates the record assignment phase of routing: locks a candidate
 *              record, updates its owner field, increments agent load, and returns the outcome.
 *
 *              v2 changes:
 *              • Status values use consolidated uppercase constants (ASSIGNED, NO_MATCH, etc.)
 *              • On successful assignment: increments Agent__c.Current_Load__c and sets
 *                Last_Assigned__c timestamp via a second DML update
 *              • maxRetryAttempts passed through to RetryLockHandler from ConfigBundle
 *
 *              Security:
 *              • DML uses AccessLevel.USER_MODE — respects CRUD/FLS.
 *              • All SOQL is delegated to AssignmentSelector (bind-variable only, USER_MODE).
 *
 *              Governor awareness:
 *              • 1–2 DML (record update + agent load update) on success. 0 DML on failure.
 *              • SOQL cost is bounded by RetryLockHandler (maxRetries × candidates tried).
 *
 * @group Worker
 */
public with sharing class AssignmentResolver {

    private static final String CLS = 'AssignmentResolver';

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
     * @description Creates a generic failure outcome for engine-level exceptions.
     *              Public so RoutingEngine can create audit-loggable outcomes.
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

    /**
     * @description Creates outcome for capability mismatch failures.
     *              Public so RoutingEngine can create audit-loggable outcomes.
     *
     * @param errorMessage Description of the capability mismatch
     * @return Failure outcome with status 'Capability_Mismatch'
     */
    public static AssignmentOutcome outcomeCapabilityMismatch(String errorMessage) {
        AssignmentOutcome o = new AssignmentOutcome();
        o.success = false;
        o.lockContention = false;
        o.retryCount = 0;
        o.candidateCount = 0;
        o.status = 'Capability_Mismatch';
        o.errorMessage = errorMessage;
        return o;
    }

    /**
     * @description Creates outcome for capacity exceeded failures.
     *
     * @param errorMessage Description of the capacity limit
     * @return Failure outcome with status 'Capacity_Exceeded'
     */
    public static AssignmentOutcome outcomeCapacityExceeded(String errorMessage) {
        AssignmentOutcome o = new AssignmentOutcome();
        o.success = false;
        o.lockContention = false;
        o.retryCount = 0;
        o.candidateCount = 0;
        o.status = 'Capacity_Exceeded';
        o.errorMessage = errorMessage;
        return o;
    }

    // ─── Public API ───────────────────────────────────────────────────────────

    /**
     * @description Resolves assignment for a single ConfigBundle: checks existing
     *              assignments, locks a candidate, updates ownership, increments agent load.
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

        // ─── Lock first available candidate (uses config's maxRetryAttempts) ─
        RetryLockHandler.RetryOutcome lockOutcome = RetryLockHandler.lockFirstAvailable(
            bundle.objectApiName,
            bundle.ownerFieldApiName,
            candidates,
            bundle.maxRetryAttempts
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

            // ─── Increment agent load + set Last_Assigned__c ────────────
            incrementAgentLoad(agentUserId);

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

    /**
     * @description Increments Agent__c.Current_Load__c by 1 and sets Last_Assigned__c.
     *              Non-fatal — if the update fails (FLS, agent not found), routing still
     *              succeeds but a warning is logged.
     *
     * @param agentUserId The agent's User Id (used to look up Agent__c)
     */
    private static void incrementAgentLoad(Id agentUserId) {
        try {
            Map<Id, Agent__c> agentsByUser =
                AgentCapabilitySelector.getActiveAgentsByUserId();
            Agent__c agent = agentsByUser.get(agentUserId);

            if (agent == null) {
                URE_Logger.debug('No Agent__c found for load increment | user=' + agentUserId)
                    .category(URE_Logger.Category.ASSIGNMENT)
                    .inClass(CLS).inMethod('incrementAgentLoad')
                    .log();
                return;
            }

            Decimal currentLoad = (agent.Current_Load__c != null) ? agent.Current_Load__c : 0;
            agent.Current_Load__c = currentLoad + 1;
            agent.Last_Assigned__c = System.now();

            Database.update(agent, false, AccessLevel.USER_MODE);

            URE_Logger.debug('Agent load incremented | user=' + agentUserId
                    + ' | newLoad=' + agent.Current_Load__c)
                .category(URE_Logger.Category.ASSIGNMENT)
                .inClass(CLS).inMethod('incrementAgentLoad')
                .log();

        } catch (Exception ex) {
            // Non-fatal — routing succeeded, but load tracking failed
            URE_Logger.warn('Failed to increment agent load | user=' + agentUserId
                    + ' | reason=' + ex.getMessage())
                .category(URE_Logger.Category.ASSIGNMENT)
                .inClass(CLS).inMethod('incrementAgentLoad')
                .log();
        }
    }

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
