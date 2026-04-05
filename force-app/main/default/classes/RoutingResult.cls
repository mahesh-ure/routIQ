/**
 * @description Data Transfer Object for routing outcomes. Returned by the routing engine
 *              to all callers (Flow, REST, LWC). Created exclusively via static factory
 *              methods — never instantiated directly by external code.
 *
 *              Factory methods:
 *                RoutingResult.success(recordId, assignedTo, routingLogId, retryCount)
 *                RoutingResult.failure(errorMessage)
 *                RoutingResult.noMatch()
 *
 * @group Entry
 */
global with sharing class RoutingResult {

    @AuraEnabled
    @InvocableVariable(label='Record Id' description='ID of the routed record' required=false)
    global String recordId;

    @AuraEnabled
    @InvocableVariable(label='Success' description='True if a record was successfully assigned' required=false)
    global Boolean success;

    @AuraEnabled
    @InvocableVariable(label='Assigned To' description='User ID of the agent who received the assignment' required=false)
    global String assignedTo;

    @AuraEnabled
    @InvocableVariable(label='Routing Log Id' description='ID of the Routing Log audit record' required=false)
    global String routingLogId;

    @AuraEnabled
    @InvocableVariable(label='Error Message' description='Blank on success. Describes the failure reason.' required=false)
    global String errorMessage;

    @AuraEnabled
    @InvocableVariable(label='Object API Name' description='API name of the routed SObject (e.g. Case, Loan_Application__c)' required=false)
    global String objectApiName;

    @AuraEnabled
    @InvocableVariable(label='Record Name' description='Display name of the routed record (e.g. CaseNumber for Case, Name for custom objects)' required=false)
    global String recordName;

    @AuraEnabled
    @InvocableVariable(label='Entry Point' description='Integration surface that initiated routing (InvocableMethod, REST, LWC, GlobalAction)' required=false)
    global String entryPoint;

    @AuraEnabled
    @InvocableVariable(label='Retry Count' description='Number of FOR UPDATE lock retries before resolution' required=false)
    global Integer retryCount;

    // ═══════════════════════════════════════════════════════════════════════════
    // P1 ADDITIONS — Layer 0 schema lockdown (declarations only, no logic)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @description Human-readable summary of the routing decision. Examples:
     *              "Assigned to [Agent Name] — 2 of 2 conditions matched, capacity 3/5,
     *               SLA proximity rank 1."
     *              "No match — 0 agents hold all required capabilities."
     *
     *              Populated by RoutingEngine during Layer 2 for all outcomes
     *              (ASSIGNED, NO_MATCH, DEFERRED). Used by the Setup Wizard simulate
     *              step and the Supervisor Dashboard.
     */
    @AuraEnabled
    global String reasonSummary;

    /**
     * @description Ordered list of condition evaluation traces. One entry per
     *              Routing_Condition__mdt evaluated during matching. Populated
     *              regardless of dryRun — always available for debugging.
     *
     *              Used by:
     *              - Setup Wizard simulate step (Layer 7 — dryRun display)
     *              - P2 Simulator (future)
     *              - Supervisor Dashboard routing detail view
     *
     *              Not exposed as @InvocableVariable — List of custom types is
     *              not serializable in Flow. Access via Apex or LWC only.
     */
    @AuraEnabled
    global List<RoutingConditionTrace> conditionTraces;

    // ─── Private constructor — use factory methods ───────────────────────────

    @TestVisible
    private RoutingResult() {
    }

    // ─── Factory methods ─────────────────────────────────────────────────────

    /**
     * @description Creates a successful routing result.
     * @param recordId   ID of the record that was assigned
     * @param assignedTo User ID of the agent who received the assignment
     * @param routingLogId ID of the Routing Log audit record
     * @param retryCount Number of lock retries that occurred (0 = no contention)
     * @return Fully populated success result
     */
    global static RoutingResult success(
        String recordId,
        String assignedTo,
        String routingLogId,
        Integer retryCount
    ) {
        RoutingResult result = new RoutingResult();
        result.recordId = recordId;
        result.success = true;
        result.assignedTo = assignedTo;
        result.routingLogId = routingLogId;
        result.retryCount = retryCount;
        return result;
    }

    /**
     * @description Creates a failure result for a specific record.
     * @param recordId     ID of the record that failed to route (may be null)
     * @param errorMessage Human-readable description of the failure
     * @return Failure result with error details
     */
    global static RoutingResult failure(String recordId, String errorMessage) {
        RoutingResult result = new RoutingResult();
        result.recordId = recordId;
        result.success = false;
        result.errorMessage = errorMessage;
        return result;
    }

    /**
     * @description Creates a no-match result when no candidates satisfy the conditions.
     *              Distinct from failure — the engine executed correctly, but the query
     *              returned zero candidates.
     * @return No-match result with success=false and descriptive message
     */
    global static RoutingResult noMatch() {
        RoutingResult result = new RoutingResult();
        result.success = false;
        result.errorMessage = 'No matching candidates found.';
        result.retryCount = 0;
        return result;
    }
}
