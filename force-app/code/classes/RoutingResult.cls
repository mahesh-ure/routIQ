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

    @InvocableVariable(label='Record Id' description='ID of the routed record' required=false)
    global String recordId;

    @InvocableVariable(label='Success' description='True if a record was successfully assigned' required=false)
    global Boolean success;

    @InvocableVariable(label='Assigned To' description='User ID of the agent who received the assignment' required=false)
    global String assignedTo;

    @InvocableVariable(label='Routing Log Id' description='ID of the Routing Log audit record' required=false)
    global String routingLogId;

    @InvocableVariable(label='Error Message' description='Blank on success. Describes the failure reason.' required=false)
    global String errorMessage;

    @InvocableVariable(label='Object API Name' description='API name of the routed SObject (e.g. Case, Loan_Application__c)' required=false)
    global String objectApiName;

    @InvocableVariable(label='Record Name' description='Display name of the routed record (e.g. CaseNumber for Case, Name for custom objects)' required=false)
    global String recordName;

    @InvocableVariable(label='Entry Point' description='Integration surface that initiated routing (InvocableMethod, REST, LWC, GlobalAction)' required=false)
    global String entryPoint;

    @InvocableVariable(label='Retry Count' description='Number of FOR UPDATE lock retries before resolution' required=false)
    global Integer retryCount;

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
