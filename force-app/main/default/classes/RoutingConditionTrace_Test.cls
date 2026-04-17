/**
 * @description Test class for RoutingConditionTrace (Domain DTO).
 *              Tests: trace data population, layer tracking,
 *              execution flow documentation.
 *
 * @group Test
 */
@IsTest
private class RoutingConditionTrace_Test {

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. Trace Object Construction
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void construct_trace() {
        Test.startTest();
        RoutingConditionTrace trace = new RoutingConditionTrace();
        Test.stopTest();

        System.assertNotEquals(null, trace,
            'RoutingConditionTrace should be constructible');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. Phase Name Tracking
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void populate_phaseName() {
        Test.startTest();
        RoutingConditionTrace trace = new RoutingConditionTrace();
        trace.phaseName = 'Validation';
        Test.stopTest();

        System.assertEquals('Validation', trace.phaseName,
            'Phase name should be settable');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. Config Name Tracking
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void populate_configName() {
        Test.startTest();
        RoutingConditionTrace trace = new RoutingConditionTrace();
        trace.configName = 'Support_Standard';
        Test.stopTest();

        System.assertEquals('Support_Standard', trace.configName,
            'Config name should be settable');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. Condition Details
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void populate_conditionDetails() {
        Test.startTest();
        RoutingConditionTrace trace = new RoutingConditionTrace();
        trace.conditionField = 'Priority';
        trace.operator = 'EQUALS';
        trace.expectedValue = 'High';
        trace.actualValue = 'High';
        Test.stopTest();

        System.assertEquals('Priority', trace.conditionField,
            'Condition field should be settable');
        System.assertEquals('EQUALS', trace.operator,
            'Operator should be settable');
        System.assertEquals('High', trace.expectedValue,
            'Expected value should be settable');
        System.assertEquals('High', trace.actualValue,
            'Actual value should be settable');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 5. Match Result
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void populate_matchResult() {
        Test.startTest();
        RoutingConditionTrace trace = new RoutingConditionTrace();
        trace.matched = true;
        Test.stopTest();

        System.assertEquals(true, trace.matched,
            'Match result should be settable');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 6. Layer Information
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void populate_layerInfo() {
        Test.startTest();
        RoutingConditionTrace trace = new RoutingConditionTrace();
        trace.layerName = 'RuleEvaluator';
        trace.methodName = 'evaluate';
        Test.stopTest();

        System.assertEquals('RuleEvaluator', trace.layerName,
            'Layer name should be settable');
        System.assertEquals('evaluate', trace.methodName,
            'Method name should be settable');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 7. Timestamp Tracking
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void populate_timestamp() {
        Test.startTest();
        RoutingConditionTrace trace = new RoutingConditionTrace();
        trace.timestamp = System.now();
        Test.stopTest();

        System.assertNotEquals(null, trace.timestamp,
            'Timestamp should be settable');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 8. Error Message Tracking
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void populate_errorMessage() {
        Test.startTest();
        RoutingConditionTrace trace = new RoutingConditionTrace();
        trace.errorMessage = 'No matching records found';
        Test.stopTest();

        System.assertEquals('No matching records found', trace.errorMessage,
            'Error message should be settable');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 9. Null Fields (All Optional)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void nullFields_optional() {
        Test.startTest();
        RoutingConditionTrace trace = new RoutingConditionTrace();
        // All fields default to null
        Test.stopTest();

        System.assertEquals(null, trace.phaseName,
            'Fields should default to null');
        System.assertEquals(null, trace.configName,
            'Fields should default to null');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 10. JSON Serialization
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void serialize_toJSON() {
        RoutingConditionTrace trace = new RoutingConditionTrace();
        trace.phaseName = 'Test';
        trace.configName = 'TestConfig';
        trace.matched = true;

        Test.startTest();
        String json = JSON.serialize(trace);
        Test.stopTest();

        System.assertNotEquals(null, json,
            'Trace should be JSON serializable');
        System.assert(json.contains('phaseName'),
            'JSON should contain phase name');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 11. Multiple Trace Collection
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void collect_multipleTraces() {
        List<RoutingConditionTrace> traces = new List<RoutingConditionTrace>();

        Test.startTest();
        for (Integer i = 0; i < 5; i++) {
            RoutingConditionTrace trace = new RoutingConditionTrace();
            trace.phaseName = 'Phase ' + i;
            traces.add(trace);
        }
        Test.stopTest();

        System.assertEquals(5, traces.size(),
            'Should support collecting multiple traces');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 12. Complete Trace Data
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void populateFullTrace() {
        Test.startTest();
        RoutingConditionTrace trace = new RoutingConditionTrace();
        trace.phaseName = 'Candidate Matching';
        trace.configName = 'Support_Config';
        trace.conditionField = 'Priority';
        trace.operator = 'EQUALS';
        trace.expectedValue = 'High';
        trace.actualValue = 'High';
        trace.matched = true;
        trace.layerName = 'AgentMatcher';
        trace.methodName = 'evaluate';
        trace.timestamp = System.now();
        Test.stopTest();

        System.assertNotEquals(null, trace.phaseName,
            'Full trace should be populated');
        System.assertNotEquals(null, trace.conditionField,
            'Condition details should be set');
        System.assertEquals(true, trace.matched,
            'Match result should be set');
    }
}
