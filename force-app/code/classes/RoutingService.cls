/**
 * @description Global entry point for the routIQ routing engine. Exposes three
 *              integration surfaces — Flow, REST, and LWC — that all converge on
 *              RoutingEngine.execute() via a single private dispatch method.
 *
 *              Integration surfaces:
 *              ┌────────────────────┬──────────────────────────────────────────┐
 *              │ @InvocableMethod   │ Flow Builder / Process Builder          │
 *              │ @HttpPost          │ External systems via REST API           │
 *              │ @AuraEnabled       │ Lightning Web Components               │
 *              └────────────────────┴──────────────────────────────────────────┘
 *
 *              All three share the same contract:
 *              • Input:  RoutingRequest (objectApiName, recordId, configDeveloperName)
 *              • Output: RoutingResult  (recordId, success, assignedTo, routingLogId, …)
 *              • Agent:  UserInfo.getUserId() — the running user is always the agent
 *
 *              Error handling: this class NEVER throws exceptions to callers. Every
 *              failure is captured in RoutingResult.failure() so consumers (Flow,
 *              LWC, REST clients) always receive a structured response.
 *
 *              Security:
 *              • global with sharing — respects org sharing rules.
 *              • global access required by managed package for subscriber visibility.
 *              • All downstream classes enforce AccessLevel.USER_MODE for CRUD/FLS.
 *
 *              Governor cost: zero — all SOQL and DML are in downstream workers/selectors.
 *
 * @group Entry
 */
@RestResource(urlMapping='/routing/*')
global with sharing class RoutingService {

    // ═══════════════════════════════════════════════════════════════════════════
    // FLOW ENTRY POINT
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @description Invocable action for Flow Builder and Process Builder.
     *
     *              Flow admins drag this action onto the canvas, map RoutingRequest
     *              fields, and receive RoutingResult outputs. Flow calls this with
     *              a list (typically size 1 for screen flows, potentially larger for
     *              auto-launched/scheduled flows).
     *
     *              Each request is processed independently — one failure does not
     *              block others in the list.
     *
     * @param requests List of RoutingRequest DTOs from Flow
     * @return List of RoutingResult DTOs (same size, same order as input)
     */
    @InvocableMethod(
        label='Route Record'
        description='Finds the best candidate record and assigns it to the current user. Use for agent "Get Next" buttons, auto-routing flows, or record-specific routing.'
        category='routIQ'
    )
    global static List<RoutingResult> invoke(List<RoutingRequest> requests) {
        List<RoutingResult> results = new List<RoutingResult>();

        if (requests == null || requests.isEmpty()) {
            return results;
        }

        for (RoutingRequest req : requests) {
            results.add(executeSingle(req, 'InvocableMethod'));
        }

        return results;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // REST ENTRY POINT
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @description REST API endpoint for external system integration.
     *
     *              URL:  POST /services/apexrest/{namespace}/routing/
     *              Body: JSON matching RoutingRequest structure
     *                    {
     *                      "objectApiName": "Case",
     *                      "recordId": "500xx0000001234AAA",
     *                      "configDeveloperName": "High_Priority_Cases"
     *                    }
     *
     *              All fields are optional:
     *              • Blank body → "Get Next" across all configs
     *              • objectApiName only → "Get Next" for that object type
     *              • recordId + objectApiName → route this specific record
     *
     *              Response: JSON matching RoutingResult structure (auto-serialized)
     *              HTTP 200 always — check response.success for business outcome.
     *
     * @return RoutingResult serialized as JSON response body
     */
    @HttpPost
    global static RoutingResult routeRecord() {
        RestRequest restReq = RestContext.request;

        RoutingRequest request;
        try {
            String body = (restReq.requestBody != null)
                ? restReq.requestBody.toString()
                : '{}';

            request = (RoutingRequest) JSON.deserialize(
                body, RoutingRequest.class
            );
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR,
                'RoutingService.routeRecord: malformed JSON body: '
                + ex.getMessage());
            RestContext.response.statusCode = 400;
            return RoutingResult.failure(
                null,
                'Malformed request body: ' + ex.getMessage()
            );
        }

        return executeSingle(request, 'REST');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LWC ENTRY POINT
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @description AuraEnabled method for Lightning Web Components.
     *
     *              Called imperatively from LWC JavaScript:
     *                import routeRecord from '@salesforce/apex/RoutingService.getNextRecord';
     *                const result = await routeRecord({
     *                    objectApiName: 'Case',
     *                    recordId: null,
     *                    configDeveloperName: null
     *                });
     *
     *              Uses discrete parameters (not a JSON string) for clean LWC
     *              developer experience — no manual serialization needed on the
     *              client side.
     *
     *              Not cacheable — this method mutates data (assigns record ownership).
     *
     * @param objectApiName     SObject API name (optional — null for "Get Next" across all)
     * @param recordId          Specific record to route (optional)
     * @param configDeveloperName Target a specific routing config (optional)
     * @return RoutingResult with assignment details or failure reason
     */
    @AuraEnabled
    global static RoutingResult getNextRecord(
        String objectApiName,
        String recordId,
        String configDeveloperName
    ) {
        RoutingRequest request = new RoutingRequest();
        request.objectApiName = objectApiName;
        request.recordId = recordId;
        request.configDeveloperName = configDeveloperName;

        return executeSingle(request, 'LWC');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // COMMON DISPATCH
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @description Single execution path for all three entry points. Wraps
     *              RoutingEngine.execute() in a top-level exception handler so
     *              callers ALWAYS receive a RoutingResult, never an unhandled exception.
     *
     *              The running user (UserInfo.getUserId()) is the agent in the pull
     *              model — the person who clicked "Get Next" or triggered the Flow.
     *
     * @param request    Populated RoutingRequest DTO
     * @param entryPoint Origin identifier: InvocableMethod, REST, LWC, GlobalAction
     * @return RoutingResult — always non-null, always structured
     */
    private static RoutingResult executeSingle(
        RoutingRequest request,
        String entryPoint
    ) {
        try {
            Id agentUserId = UserInfo.getUserId();

            RoutingResult result = RoutingEngine.execute(
                request, agentUserId, entryPoint
            );

            // Ensure entryPoint is stamped (engine may not set it on all paths)
            if (result.entryPoint == null) {
                result.entryPoint = entryPoint;
            }

            return result;

        } catch (Exception ex) {
            // Last-resort safety net — should never reach here because
            // RoutingEngine handles exceptions internally, but defense-in-depth
            // ensures callers always get a structured response.
            System.debug(LoggingLevel.ERROR,
                'RoutingService: unhandled exception in ' + entryPoint
                + ': ' + ex.getMessage()
                + '\n' + ex.getStackTraceString());

            RoutingResult failResult = RoutingResult.failure(
                (request != null) ? request.recordId : null,
                'Internal routing error: ' + ex.getMessage()
            );
            failResult.entryPoint = entryPoint;
            return failResult;
        }
    }
}
