/**
 * @description Layer 4 — Invocable Action for Flow Builder integration.
 *              Provides a dedicated, Flow-friendly action that wraps RoutingService
 *              with structured input/output DTOs. Each request is processed
 *              independently with per-record try/catch for bulk safety.
 *
 *              Design:
 *              • Separate from RoutingService.invoke() to give Flow admins a
 *                simpler, labelled interface without exposing internal DTOs.
 *              • All SOQL is batched inside RoutingEngine — this class is zero-SOQL.
 *              • configDevName is optional — null routes via all active configs.
 *
 * @group Entry
 */
global with sharing class RoutingInvocableAction {

    // ─── Input DTO ──────────────────────────────────────────────────────────

    global class RoutingInvocableRequest {
        @InvocableVariable(label='Record Id' required=true
            description='Id of the record to route')
        global Id recordId;

        @InvocableVariable(label='Config Developer Name' required=false
            description='Optional: target a specific Routing Config by DeveloperName')
        global String configDevName;
    }

    // ─── Output DTO ─────────────────────────────────────────────────────────

    global class RoutingInvocableResult {
        @InvocableVariable(label='Assigned Agent Id'
            description='Agent__c.User__c of the assigned agent')
        global String assignedAgentId;

        @InvocableVariable(label='Assigned Agent Name'
            description='Display name of the assigned agent')
        global String assignedAgentName;

        @InvocableVariable(label='Success'
            description='True if record was successfully routed')
        global Boolean success;

        @InvocableVariable(label='Error Message'
            description='Blank on success; describes failure reason')
        global String errorMessage;
    }

    // ─── Invocable Method ───────────────────────────────────────────────────

    @InvocableMethod(
        label='Route record via routIQ'
        description='Routes a record through the routIQ engine and returns the assigned agent. Supports bulk — each record processed independently.'
        category='routIQ'
    )
    global static List<RoutingInvocableResult> routeRecords(
        List<RoutingInvocableRequest> requests
    ) {
        List<RoutingInvocableResult> results = new List<RoutingInvocableResult>();

        if (requests == null || requests.isEmpty()) {
            return results;
        }

        for (RoutingInvocableRequest req : requests) {
            results.add(processSingle(req));
        }

        return results;
    }

    // ─── Private ────────────────────────────────────────────────────────────

    private static RoutingInvocableResult processSingle(
        RoutingInvocableRequest req
    ) {
        RoutingInvocableResult res = new RoutingInvocableResult();

        try {
            RoutingRequest engineReq = new RoutingRequest();
            engineReq.recordId = (req.recordId != null)
                ? String.valueOf(req.recordId) : null;
            engineReq.configDeveloperName = req.configDevName;

            RoutingResult engineResult = RoutingService.getNextRecord(
                null,
                engineReq.recordId,
                engineReq.configDeveloperName,
                false
            );

            res.success = engineResult.success;
            res.assignedAgentId = engineResult.assignedTo;
            res.assignedAgentName = engineResult.recordName;
            res.errorMessage = engineResult.errorMessage;

        } catch (Exception ex) {
            res.success = false;
            res.errorMessage = ex.getMessage();
        }

        return res;
    }
}
