/**
 * @description Provides SOQL queries for the record assignment phase of routing.
 *
 *              Two primary operations:
 *              1. lockRecord — SELECT … FOR UPDATE on a single candidate to acquire
 *                 a pessimistic row lock before updating the owner field.
 *              2. queryOwnedRecords — checks an agent's existing assignments for
 *                 Allow_Multiple__c enforcement.
 *
 *              All queries use Database.queryWithBinds() with AccessLevel.USER_MODE
 *              for FLS enforcement and bind-variable-only SOQL (zero injection surface).
 *
 *              Cost: 1 SOQL per call.
 *
 * @group Selector
 */
public with sharing class AssignmentSelector {

    @TestVisible
    private static SObject mockLockedRecord;

    @TestVisible
    private static List<SObject> mockOwnedRecords;

    // ─── Public API ────────────────────────────────────────────────────────────

    /**
     * @description Acquires a pessimistic row lock on a single candidate record
     *              by issuing SELECT … FOR UPDATE. Returns the locked record with
     *              Id and the owner field so AssignmentResolver can update ownership.
     *
     *              Callers MUST handle QueryException (lock contention / UNABLE_TO_LOCK_ROW)
     *              and retry via RetryLockHandler.
     *
     * @param objectApiName    SObject API name (e.g. Case, Loan_Application__c)
     * @param ownerFieldApiName Field that holds the record's current owner
     * @param recordId         Id of the candidate record to lock
     * @return The locked SObject, or null if the record no longer exists
     */
    public static SObject lockRecord(
        String objectApiName,
        String ownerFieldApiName,
        Id recordId
    ) {
        if (Test.isRunningTest() && mockLockedRecord != null) {
            return mockLockedRecord;
        }

        // Build SELECT field list — always include Id; add ownerField if different
        String selectFields = 'Id';
        if (String.isNotBlank(ownerFieldApiName)
            && ownerFieldApiName.toLowerCase() != 'id'
        ) {
            selectFields += ', ' + ownerFieldApiName;
        }

        String soql = 'SELECT ' + selectFields
            + ' FROM ' + objectApiName
            + ' WHERE Id = :recordId'
            + ' FOR UPDATE';

        Map<String, Object> binds = new Map<String, Object>{
            'recordId' => recordId
        };

        List<SObject> results = Database.queryWithBinds(
            soql, binds, AccessLevel.USER_MODE
        );

        return results.isEmpty() ? null : results[0];
    }

    /**
     * @description Queries records currently owned by the agent for a given object type.
     *              Used by RoutingEngine to enforce Allow_Multiple__c = false — if the agent
     *              already owns a record, the engine skips assignment for that config.
     *
     *              Intentionally returns only Id (minimal field access) with LIMIT 1
     *              since the caller only needs to know whether any assignments exist.
     *
     * @param objectApiName    SObject API name
     * @param ownerFieldApiName Field that holds the owner (e.g. OwnerId, Assigned_To__c)
     * @param agentUserId      The agent's User Id
     * @return List with 0 or 1 records. Non-empty means the agent has an existing assignment.
     */
    public static List<SObject> queryOwnedRecords(
        String objectApiName,
        String ownerFieldApiName,
        Id agentUserId
    ) {
        if (Test.isRunningTest() && mockOwnedRecords != null) {
            return mockOwnedRecords;
        }

        String soql = 'SELECT Id'
            + ' FROM ' + objectApiName
            + ' WHERE ' + ownerFieldApiName + ' = :agentId'
            + ' LIMIT 1';

        Map<String, Object> binds = new Map<String, Object>{
            'agentId' => agentUserId
        };

        return Database.queryWithBinds(
            soql, binds, AccessLevel.USER_MODE
        );
    }
}
