/**
 * @description Provides SOQL queries for the record assignment phase of routing.
 *
 *              Two primary operations:
 *              1. lockRecord — SELECT … FOR UPDATE on a single candidate to acquire
 *                 a pessimistic row lock before updating the owner field.
 *              2. queryOwnedRecords — counts an agent's open records for the
 *                 Phase 3 Open Work Item Gate (Max_Capacity__c enforcement).
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

    @TestVisible
    private static String mockRecordName;

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
     * @description Queries the OPEN records currently owned by an agent for
     *              a given routing config. Used by RoutingEngine's Phase 3
     *              capacity gate.
     *
     *              Two metadata-driven dimensions:
     *              1. Closed-status filter — when
     *                 Routing_Config__mdt.Closed_Status_Field_API_Name__c and
     *                 Closed_Status_Values__c are both supplied, the query
     *                 adds "<statusField> NOT IN :closedValues" so already-
     *                 completed records never block new assignments (fixes
     *                 the latent capacity-gate bug where the owner field
     *                 does not change when a record is closed).
     *              2. Per-config capacity — LIMIT is driven by
     *                 Routing_Config__mdt.Max_Capacity__c. Caller compares
     *                 results.size() to maxCapacity to decide "at cap".
     *                 Caller should pass 1 when maxCapacity is null/zero.
     *
     *              Minimal field access (Id only) — the caller only needs
     *              to count rows.
     *
     * @param objectApiName             SObject API name
     * @param ownerFieldApiName         Owner field (OwnerId, Assigned_To__c, …)
     * @param agentUserId               The agent's User Id
     * @param closedStatusFieldApiName  Optional — status field API name
     *                                  (Status, StageName, State__c). Blank
     *                                  disables closed-status filtering.
     * @param closedStatusValues        Optional — values considered closed.
     *                                  Empty/null disables filtering.
     * @param maxCapacity               Per-config capacity ceiling. Drives
     *                                  LIMIT. Must be >= 1 (caller defaults
     *                                  null/0 to 1).
     * @return Up to maxCapacity rows. Caller treats size >= maxCapacity as
     *         "agent at cap for this config".
     */
    public static List<SObject> queryOwnedRecords(
        String objectApiName,
        String ownerFieldApiName,
        Id agentUserId,
        String closedStatusFieldApiName,
        List<String> closedStatusValues,
        Integer maxCapacity
    ) {
        if (Test.isRunningTest() && mockOwnedRecords != null) {
            return mockOwnedRecords;
        }

        // Defensive floor — never issue an invalid LIMIT
        Integer effectiveLimit = (maxCapacity != null && maxCapacity > 0)
            ? maxCapacity
            : 1;

        Boolean filterClosed =
               String.isNotBlank(closedStatusFieldApiName)
            && closedStatusValues != null
            && !closedStatusValues.isEmpty();

        String soql = 'SELECT Id'
            + ' FROM ' + objectApiName
            + ' WHERE ' + ownerFieldApiName + ' = :agentId';

        Map<String, Object> binds = new Map<String, Object>{
            'agentId' => agentUserId
        };

        if (filterClosed) {
            soql += ' AND ' + closedStatusFieldApiName
                 + ' NOT IN :closedValues';
            binds.put('closedValues', closedStatusValues);
        }

        soql += ' LIMIT :limitValue';
        binds.put('limitValue', effectiveLimit);

        return Database.queryWithBinds(
            soql, binds, AccessLevel.USER_MODE
        );
    }

    /**
     * @description Fetches the display name of a record using the SObject's name field
     *              determined via Schema describe (isNameField). Handles all SObject types:
     *              Account→Name, Case→CaseNumber, custom objects→Name, etc.
     *
     *              Non-fatal — returns null on any failure so the UI can fall back to
     *              displaying the record Id. Uses AccessLevel.USER_MODE for FLS enforcement.
     *
     *              Cost: 1 describe (platform-cached) + 1 SOQL.
     *
     * @param objectApiName SObject API name (from ConfigBundle, trusted CMDT source)
     * @param recordId      Id of the assigned record
     * @return Display name string, or null if unavailable
     */
    public static String queryRecordName(String objectApiName, Id recordId) {
        if (Test.isRunningTest() && mockRecordName != null) {
            return mockRecordName;
        }

        if (String.isBlank(objectApiName) || recordId == null) {
            return null;
        }

        try {
            Schema.SObjectType sot = Schema.getGlobalDescribe().get(objectApiName);
            if (sot == null) {
                return null;
            }

            // Find the name field via describe — isNameField() returns true for
            // the object's display name (Name, CaseNumber, SolutionName, etc.)
            String nameField = null;
            for (Schema.SObjectField field : sot.getDescribe().fields.getMap().values()) {
                if (field.getDescribe().isNameField()) {
                    nameField = field.getDescribe().getName();
                    break;
                }
            }

            if (nameField == null) {
                return null;
            }

            // Field and object names from describe/CMDT — safe for concatenation
            String soql = 'SELECT ' + nameField
                + ' FROM ' + objectApiName
                + ' WHERE Id = :recordId LIMIT 1';

            List<SObject> records = Database.queryWithBinds(
                soql,
                new Map<String, Object>{ 'recordId' => recordId },
                AccessLevel.USER_MODE
            );

            return records.isEmpty()
                ? null
                : String.valueOf(records[0].get(nameField));
        } catch (Exception ex) {
            // Non-fatal — UI falls back to recordId display
            return null;
        }
    }
}
