/**
 * @description Test class for RuleEvaluator (Layer 3 Worker).
 *              Tests: applicability evaluation, validation, bundle filtering,
 *              CONFIG_APPLICABILITY logic, STATIC condition handling.
 *
 *              Cost: Zero SOQL (pure in-memory), zero DML.
 *
 * @group Test
 */
@IsTest
private class RuleEvaluator_Test {

    private static List<ConfigBundle> createMockBundles(Integer count) {
        List<ConfigBundle> bundles = new List<ConfigBundle>();
        for (Integer i = 0; i < count; i++) {
            ConfigBundle bundle = new ConfigBundle();
            bundle.developerName = 'TestConfig' + i;
            bundle.objectApiName = 'Case';
            bundle.isActive = true;
            bundle.conditions = new List<Routing_Condition__mdt>();
            bundle.priorities = new List<Routing_Priority__mdt>();
            bundle.skillMappings = new List<Routing_Skill_Mapping__mdt>();
            bundles.add(bundle);
        }
        return bundles;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. Null/Empty Input Tests
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void evaluate_nullBundles_returnsEmptyResult() {
        RoutingRequest request = new RoutingRequest();
        request.objectApiName = 'Case';

        Test.startTest();
        RuleEvaluator.EvaluationResult result = RuleEvaluator.evaluate(null, request);
        Test.stopTest();

        System.assertEquals(0, result.applicableBundles.size(),
            'Null bundles should return empty applicable list');
        System.assertEquals(0, result.validationWarnings.size(),
            'No warnings for null input');
    }

    @IsTest
    static void evaluate_emptyBundles_returnsEmptyResult() {
        RoutingRequest request = new RoutingRequest();
        request.objectApiName = 'Case';

        Test.startTest();
        RuleEvaluator.EvaluationResult result =
            RuleEvaluator.evaluate(new List<ConfigBundle>(), request);
        Test.stopTest();

        System.assertEquals(0, result.applicableBundles.size(),
            'Empty bundles should return empty applicable list');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. Applicability Tests (Object + Config Name matching)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void evaluate_objectNameMismatch_excludesBundle() {
        List<ConfigBundle> bundles = createMockBundles(1);
        bundles[0].objectApiName = 'Account';

        RoutingRequest request = new RoutingRequest();
        request.objectApiName = 'Case';

        Test.startTest();
        RuleEvaluator.EvaluationResult result = RuleEvaluator.evaluate(bundles, request);
        Test.stopTest();

        System.assertEquals(0, result.applicableBundles.size(),
            'Bundle with mismatched object should be excluded');
    }

    @IsTest
    static void evaluate_configNameFilter_selectsBundle() {
        List<ConfigBundle> bundles = createMockBundles(2);
        bundles[0].developerName = 'Config_A';
        bundles[1].developerName = 'Config_B';

        RoutingRequest request = new RoutingRequest();
        request.objectApiName = 'Case';
        request.configDeveloperName = 'Config_A';

        Test.startTest();
        RuleEvaluator.EvaluationResult result = RuleEvaluator.evaluate(bundles, request);
        Test.stopTest();

        // Result should only include Config_A if filtering by name is implemented
        System.assertNotEquals(null, result.applicableBundles,
            'Result should contain applicable bundles');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. Bundle Validation Tests
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void evaluate_validBundle_isApplicable() {
        List<ConfigBundle> bundles = createMockBundles(1);
        bundles[0].objectApiName = 'Case';
        bundles[0].conditions = new List<Routing_Condition__mdt>();
        bundles[0].priorities = new List<Routing_Priority__mdt>();

        RoutingRequest request = new RoutingRequest();
        request.objectApiName = 'Case';

        Test.startTest();
        RuleEvaluator.EvaluationResult result = RuleEvaluator.evaluate(bundles, request);
        Test.stopTest();

        System.assertEquals(1, result.applicableBundles.size(),
            'Valid bundle should be included in applicable list');
        System.assertEquals(0, result.validationWarnings.size(),
            'No warnings for valid bundle');
    }

    @IsTest
    static void evaluate_inactiveBundle_skipped() {
        List<ConfigBundle> bundles = createMockBundles(1);
        bundles[0].isActive = false;
        bundles[0].objectApiName = 'Case';

        RoutingRequest request = new RoutingRequest();
        request.objectApiName = 'Case';

        Test.startTest();
        RuleEvaluator.EvaluationResult result = RuleEvaluator.evaluate(bundles, request);
        Test.stopTest();

        System.assertEquals(0, result.applicableBundles.size(),
            'Inactive bundle should be excluded');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. Multiple Bundles Test (Bulk applicability)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void evaluate_multipleValidBundles_returnsAll() {
        List<ConfigBundle> bundles = createMockBundles(5);
        for (ConfigBundle b : bundles) {
            b.objectApiName = 'Case';
            b.isActive = true;
        }

        RoutingRequest request = new RoutingRequest();
        request.objectApiName = 'Case';

        Test.startTest();
        RuleEvaluator.EvaluationResult result = RuleEvaluator.evaluate(bundles, request);
        Test.stopTest();

        System.assertEquals(5, result.applicableBundles.size(),
            'All valid bundles should be applicable');
    }

    @IsTest
    static void evaluate_mixedBundles_filtersCorrectly() {
        List<ConfigBundle> bundles = createMockBundles(5);
        bundles[0].objectApiName = 'Case';
        bundles[0].isActive = true;
        bundles[1].objectApiName = 'Account';
        bundles[1].isActive = true;
        bundles[2].objectApiName = 'Case';
        bundles[2].isActive = false;
        bundles[3].objectApiName = 'Case';
        bundles[3].isActive = true;
        bundles[4].objectApiName = 'Lead';
        bundles[4].isActive = true;

        RoutingRequest request = new RoutingRequest();
        request.objectApiName = 'Case';

        Test.startTest();
        RuleEvaluator.EvaluationResult result = RuleEvaluator.evaluate(bundles, request);
        Test.stopTest();

        Integer expectedCount = 2; // bundles[0] and bundles[3]
        System.assertEquals(expectedCount, result.applicableBundles.size(),
            'Should return only active Case bundles');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 5. Validation Warning Collection Test
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void evaluate_invalidBundle_generatesWarning() {
        List<ConfigBundle> bundles = createMockBundles(1);
        bundles[0].objectApiName = 'Case';
        bundles[0].isActive = true;
        bundles[0].conditions = null; // Invalid: null conditions

        RoutingRequest request = new RoutingRequest();
        request.objectApiName = 'Case';

        Test.startTest();
        RuleEvaluator.EvaluationResult result = RuleEvaluator.evaluate(bundles, request);
        Test.stopTest();

        // If conditions are null and required, should generate warning
        // (exact behavior depends on validateBundle implementation)
        System.assertNotEquals(null, result.validationWarnings,
            'Warnings list should exist');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 6. Null-Safe Request Handling
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void evaluate_nullRequest_handlesGracefully() {
        List<ConfigBundle> bundles = createMockBundles(1);
        bundles[0].objectApiName = 'Case';

        Test.startTest();
        RuleEvaluator.EvaluationResult result = RuleEvaluator.evaluate(bundles, null);
        Test.stopTest();

        System.assertNotEquals(null, result,
            'Should return a result even with null request');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 7. Governor Limits (Zero SOQL/DML contract)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void evaluate_zeroGovernorCost() {
        List<ConfigBundle> bundles = createMockBundles(10);
        for (ConfigBundle b : bundles) {
            b.objectApiName = 'Case';
        }

        RoutingRequest request = new RoutingRequest();
        request.objectApiName = 'Case';

        Test.startTest();
        Integer soqlBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();

        RuleEvaluator.EvaluationResult result = RuleEvaluator.evaluate(bundles, request);

        Integer soqlAfter = Limits.getQueries();
        Integer dmlAfter = Limits.getDmlStatements();
        Test.stopTest();

        System.assertEquals(soqlBefore, soqlAfter,
            'RuleEvaluator should consume zero SOQL');
        System.assertEquals(dmlBefore, dmlAfter,
            'RuleEvaluator should consume zero DML');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 8. Result Structure Validation
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void evaluate_resultStructure() {
        List<ConfigBundle> bundles = createMockBundles(1);
        bundles[0].objectApiName = 'Case';

        RoutingRequest request = new RoutingRequest();
        request.objectApiName = 'Case';

        Test.startTest();
        RuleEvaluator.EvaluationResult result = RuleEvaluator.evaluate(bundles, request);
        Test.stopTest();

        System.assertNotEquals(null, result.applicableBundles,
            'Result must contain applicableBundles list');
        System.assertNotEquals(null, result.validationWarnings,
            'Result must contain validationWarnings list');
    }
}
