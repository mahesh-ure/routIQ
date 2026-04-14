/**
 * @description Global entry point for the routIQ routing engine. Exposes Flow (@InvocableMethod),
 *              REST (@HttpPost), and LWC (@AuraEnabled) surfaces — all converge on RoutingEngine.execute().
 *              Never throws to callers; failures return RoutingResult.failure(). global with sharing;
 *              downstream classes enforce CRUD/FLS via AccessLevel.USER_MODE.
 * @group Entry
 */
@RestResource(urlMapping='/routing/*')
global with sharing class RoutingService {

    // --- Flow Entry Point ---

    /** @description Invocable action for Flow/Process Builder. Each request processed independently. */
    @InvocableMethod(
        label='Route Record'
        description='Finds the best candidate record and assigns it to the current user. Use for agent "Get Next" buttons, auto-routing flows, or record-specific routing.'
        category='routIQ'
    )
    global static List<RoutingResult> invoke(List<RoutingRequest> requests) {
        List<RoutingResult> results = new List<RoutingResult>();
        if (requests == null || requests.isEmpty()) { return results; }
        for (RoutingRequest req : requests) { results.add(executeSingle(req, 'InvocableMethod')); }
        return results;
    }

    // --- REST Entry Point ---

    /**
     * @description POST /services/apexrest/{ns}/routing/ — JSON body matching RoutingRequest.
     *              All fields optional. HTTP 200 always; check response.success for outcome.
     */
    @HttpPost
    global static RoutingResult routeRecord() {
        RestRequest restReq = RestContext.request;

        RoutingRequest request;
        try {
            String body = (restReq.requestBody != null) ? restReq.requestBody.toString() : '{}';
            request = (RoutingRequest) JSON.deserialize(body, RoutingRequest.class);
        } catch (Exception ex) {
            Logger.init('REST', UserInfo.getUserId());
            Logger.error('Malformed REST JSON body')
                .category(Logger.Category.VALIDATION)
                .inClass('RoutingService').inMethod('routeRecord')
                .withException(ex)
                .log();
            Logger.flush('Failure');
            RestContext.response.statusCode = 400;
            return RoutingResult.failure(
                null,
                String.format(System.Label.URE_ROUTING_MALFORMED_REQUEST, new List<Object>{ex.getMessage()})
            );
        }

        return executeSingle(request, 'REST');
    }

    // --- LWC Entry Point ---

    /**
     * @description AuraEnabled method for LWC. dryRun=true runs full matching but skips
     *              all side effects (no DML, no events) — returns traces for simulation display.
     */
    @AuraEnabled
    global static RoutingResult getNextRecord(
        String objectApiName,
        String recordId,
        String configDeveloperName,
        Boolean dryRun
    ) {
        RoutingRequest request = new RoutingRequest();
        request.objectApiName = objectApiName;
        request.recordId = recordId;
        request.configDeveloperName = configDeveloperName;
        request.dryRun = dryRun;
        return executeSingle(request, 'LWC');
    }

    // --- Common Dispatch ---

    /**
     * @description Single execution path for all entry points. Wraps RoutingEngine.execute()
     *              in a top-level exception handler so callers ALWAYS receive a RoutingResult.
     */
    private static RoutingResult executeSingle(RoutingRequest request, String entryPoint) {
        Id agentUserId = UserInfo.getUserId();
        request.normalize();
        Logger.init(entryPoint, agentUserId);

        Logger.info('Routing started'
                + ' | txId=' + Logger.getTransactionId()
                + ' | entryPoint=' + entryPoint
                + ' | user=' + agentUserId
                + ' | object=' + request.objectApiName
                + ' | recordId=' + request.recordId
                + ' | config=' + request.configDeveloperName
                + ' | dryRun=' + request.dryRun
                + ' | v=' + Logger.FRAMEWORK_VERSION)
            .category(Logger.Category.ENGINE)
            .inClass('RoutingService').inMethod('executeSingle')
            .forConfig(request.configDeveloperName)
            .forObject(request.objectApiName)
            .withLimits()
            .log();

        String flushStatus = 'Success';
        try {
            RoutingResult result = RoutingEngine.execute(request, agentUserId, entryPoint);
            if (result.entryPoint == null) { result.entryPoint = entryPoint; }
            flushStatus = result.success ? 'Success' : 'No_Match';
            return result;
        } catch (Exception ex) {
            Logger.fatal('Unhandled exception escaped RoutingEngine')
                .category(Logger.Category.ENGINE)
                .inClass('RoutingService').inMethod('executeSingle')
                .withException(ex)
                .log();
            flushStatus = 'Failure';
            RoutingResult failResult = RoutingResult.failure(
                (request != null) ? request.recordId : null,
                String.format(System.Label.URE_ROUTING_INTERNAL_ERROR, new List<Object>{ex.getMessage()})
            );
            failResult.entryPoint = entryPoint;
            return failResult;
        } finally {
            Logger.flush(flushStatus);
        }
    }
}
