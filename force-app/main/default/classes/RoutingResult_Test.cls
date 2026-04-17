/**
 * @description Test class for RoutingResult (Layer 1 DTO).
 *              Tests: success/failure outcomes, factory methods, tracing data,
 *              JSON serialization for REST.
 *
 * @group Test
 */
@IsTest
private class RoutingResult_Test {

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. Success Factory
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void success_returnsSuccessOutcome() {
        Id recordId = UserInfo.getUserId();

        Test.startTest();
        RoutingResult result = RoutingResult.success(recordId);
        Test.stopTest();

        System.assertEquals(true, result.success,
            'Success factory should set success=true');
        System.assertEquals(recordId, result.recordId,
            'Record ID should be set');
        System.assertEquals(null, result.errorMessage,
            'No error message on success');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. Failure Factory
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void failure_returnsFailureOutcome() {
        Id recordId = UserInfo.getUserId();
        String errorMsg = System.Label.URE_ROUTING_NO_AGENT_ERROR;

        Test.startTest();
        RoutingResult result = RoutingResult.failure(recordId, errorMsg);
        Test.stopTest();

        System.assertEquals(false, result.success,
            'Failure factory should set success=false');
        System.assertEquals(recordId, result.recordId,
            'Record ID should be set');
        System.assertEquals(errorMsg, result.errorMessage,
            'Error message should be set');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. No Match Factory
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void noMatch_returnsNoMatchOutcome() {
        Test.startTest();
        RoutingResult result = RoutingResult.noMatch();
        Test.stopTest();

        System.assertEquals(false, result.success,
            'No match should be a failure');
        System.assertNotEquals(null, result.errorMessage,
            'No match should have error message');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. Traced Execution
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void result_containsTraces() {
        Id recordId = UserInfo.getUserId();

        Test.startTest();
        RoutingResult result = RoutingResult.success(recordId);
        Test.stopTest();

        System.assertNotEquals(null, result.traces,
            'Result should contain traces list');
        System.assert(result.traces instanceof List,
            'Traces should be a List');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 5. Duration Tracking
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void result_tracksDuration() {
        Id recordId = UserInfo.getUserId();

        Test.startTest();
        RoutingResult result = RoutingResult.success(recordId);
        Test.stopTest();

        System.assertNotEquals(null, result.executionTimeMs,
            'Result should track execution time');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 6. Null Error Message (Success)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void success_noErrorMessage() {
        Test.startTest();
        RoutingResult result = RoutingResult.success(UserInfo.getUserId());
        Test.stopTest();

        System.assertEquals(null, result.errorMessage,
            'Success should have null error message');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 7. Failure with Custom Message
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void failure_customMessage() {
        String customMsg = 'Custom error message';

        Test.startTest();
        RoutingResult result = RoutingResult.failure(UserInfo.getUserId(), customMsg);
        Test.stopTest();

        System.assertEquals(customMsg, result.errorMessage,
            'Custom message should be preserved');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 8. Null Record ID (Failure Case)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void failure_nullRecordId() {
        Test.startTest();
        RoutingResult result = RoutingResult.failure(null, 'Error');
        Test.stopTest();

        System.assertEquals(null, result.recordId,
            'Record ID can be null for failures');
        System.assertEquals(false, result.success,
            'Should still be a failure');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 9. Traces List Population
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void result_tracesCanBeAdded() {
        Test.startTest();
        RoutingResult result = RoutingResult.success(UserInfo.getUserId());
        RoutingConditionTrace trace = new RoutingConditionTrace();
        trace.phaseName = 'Test Phase';
        result.traces.add(trace);
        Test.stopTest();

        System.assertEquals(1, result.traces.size(),
            'Traces should be addable to result');
        System.assertEquals('Test Phase', result.traces[0].phaseName,
            'Trace data should be preserved');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 10. JSON Serialization (for REST/LWC)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void serialize_toJSON() {
        RoutingResult result = RoutingResult.success(UserInfo.getUserId());

        Test.startTest();
        String json = JSON.serialize(result);
        Test.stopTest();

        System.assertNotEquals(null, json,
            'Result should be JSON serializable');
        System.assert(json.contains('success'),
            'JSON should contain success field');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 11. JSON Deserialization (from REST)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void deserialize_fromJSON() {
        String json = '{"success":true,"recordId":"' + UserInfo.getUserId() + '","traces":[]}';

        Test.startTest();
        RoutingResult result = (RoutingResult) JSON.deserialize(json, RoutingResult.class);
        Test.stopTest();

        System.assertEquals(true, result.success,
            'Deserialized result should have correct success value');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 12. Result Fields Complete
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void result_hasAllRequiredFields() {
        RoutingResult result = RoutingResult.success(UserInfo.getUserId());

        Test.startTest();
        System.assertNotEquals(null, result.success,
            'Result must have success field');
        System.assertNotEquals(null, result.recordId,
            'Result must have recordId field');
        System.assertNotEquals(null, result.traces,
            'Result must have traces field');
        System.assertNotEquals(null, result.executionTimeMs,
            'Result must have executionTimeMs field');
        Test.stopTest();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 13. No Match Status Code
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void noMatch_hasErrorMessage() {
        Test.startTest();
        RoutingResult result = RoutingResult.noMatch();
        Test.stopTest();

        System.assertEquals(false, result.success,
            'No match should be failure');
        System.assertNotEquals(null, result.errorMessage,
            'No match should have predefined error');
    }
}
