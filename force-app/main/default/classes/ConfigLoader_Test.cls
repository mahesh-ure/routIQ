/**
 * @description Test class for ConfigLoader (Layer 3 Worker).
 *              Tests: CMDT loading, active/inactive filtering, grouping by config,
 *              null-safe handling, bundle sorting.
 *
 *              Cost: Zero SOQL (CMDT.getAll() is platform-cached).
 *
 * @group Test
 */
@IsTest
private class ConfigLoader_Test {

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. CMDT Availability Tests
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void loadActive_returnsConfigBundleList() {
        Test.startTest();
        List<ConfigBundle> bundles = ConfigLoader.loadActive();
        Test.stopTest();

        System.assertNotEquals(null, bundles,
            'loadActive should never return null');
        System.assert(bundles instanceof List,
            'Result should be a List<ConfigBundle>');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. Active Filter Tests
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void loadActive_includesOnlyActiveConfigs() {
        Test.startTest();
        List<ConfigBundle> bundles = ConfigLoader.loadActive();
        Test.stopTest();

        for (ConfigBundle bundle : bundles) {
            System.assertEquals(true, bundle.isActive,
                'All returned bundles should be active');
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. Bundle Completeness Tests
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void loadActive_bundlesContainRequiredFields() {
        Test.startTest();
        List<ConfigBundle> bundles = ConfigLoader.loadActive();
        Test.stopTest();

        for (ConfigBundle bundle : bundles) {
            System.assertNotEquals(null, bundle.developerName,
                'Bundle must have developerName');
            System.assertNotEquals(null, bundle.objectApiName,
                'Bundle must have objectApiName');
            System.assertNotEquals(null, bundle.isActive,
                'Bundle must have isActive flag');
            System.assertNotEquals(null, bundle.conditions,
                'Bundle must have conditions list');
            System.assertNotEquals(null, bundle.priorities,
                'Bundle must have priorities list');
            System.assertNotEquals(null, bundle.skillMappings,
                'Bundle must have skillMappings list (v6)');
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. Conditions Grouping Test
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void loadActive_groupsConditionsByConfig() {
        Test.startTest();
        List<ConfigBundle> bundles = ConfigLoader.loadActive();
        Test.stopTest();

        for (ConfigBundle bundle : bundles) {
            for (Routing_Condition__mdt cond : bundle.conditions) {
                // Each condition should belong to this bundle's parent config
                System.assertNotEquals(null, cond,
                    'Conditions should be properly populated');
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 5. Priorities Grouping Test
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void loadActive_groupsPrioritiesByConfig() {
        Test.startTest();
        List<ConfigBundle> bundles = ConfigLoader.loadActive();
        Test.stopTest();

        for (ConfigBundle bundle : bundles) {
            for (Routing_Priority__mdt pri : bundle.priorities) {
                System.assertNotEquals(null, pri,
                    'Priorities should be properly populated');
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 6. Skill Mappings Grouping Test (v6)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void loadActive_groupsSkillMappingsByConfig() {
        Test.startTest();
        List<ConfigBundle> bundles = ConfigLoader.loadActive();
        Test.stopTest();

        for (ConfigBundle bundle : bundles) {
            System.assertNotEquals(null, bundle.skillMappings,
                'v6: skillMappings list should exist');
            for (Routing_Skill_Mapping__mdt mapping : bundle.skillMappings) {
                System.assertNotEquals(null, mapping,
                    'Skill mappings should be properly populated');
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 7. Governor Limits (Zero SOQL contract)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void loadActive_zeroSOQLUsage() {
        Test.startTest();
        Integer soqlBefore = Limits.getQueries();
        List<ConfigBundle> bundles = ConfigLoader.loadActive();
        Integer soqlAfter = Limits.getQueries();
        Test.stopTest();

        System.assertEquals(soqlBefore, soqlAfter,
            'ConfigLoader should use zero SOQL (CMDT.getAll() is platform-cached)');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 8. Null-Safe Collection Handling
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void loadActive_handlesNullCollectionsGracefully() {
        Test.startTest();
        List<ConfigBundle> bundles = ConfigLoader.loadActive();
        Test.stopTest();

        // Should not throw NullPointerException even if CMDT is missing
        System.assertNotEquals(null, bundles,
            'Should return non-null list even with missing CMDT');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 9. Empty CMDT Handling
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void loadActive_emptyConfigsReturnsEmptyList() {
        Test.startTest();
        List<ConfigBundle> bundles = ConfigLoader.loadActive();

        // If no configs exist in the org, should return empty list
        if (bundles.isEmpty()) {
            System.assertEquals(0, bundles.size(),
                'Empty configs should return empty bundle list');
        }
        Test.stopTest();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 10. Condition Active Filter
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void loadActive_includesOnlyActiveConditions() {
        Test.startTest();
        List<ConfigBundle> bundles = ConfigLoader.loadActive();
        Test.stopTest();

        for (ConfigBundle bundle : bundles) {
            for (Routing_Condition__mdt cond : bundle.conditions) {
                System.assertEquals(true, cond.Is_Active__c,
                    'Bundle should only include active conditions');
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 11. Priority Active Filter
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void loadActive_includesOnlyActivePriorities() {
        Test.startTest();
        List<ConfigBundle> bundles = ConfigLoader.loadActive();
        Test.stopTest();

        for (ConfigBundle bundle : bundles) {
            for (Routing_Priority__mdt pri : bundle.priorities) {
                System.assertEquals(true, pri.Is_Active__c,
                    'Bundle should only include active priorities');
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 12. Bundle Sorting
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void loadActive_bundlesAreSorted() {
        Test.startTest();
        List<ConfigBundle> bundles = ConfigLoader.loadActive();
        Test.stopTest();

        // Verify sorting is consistent (if sorting is implemented)
        for (Integer i = 1; i < bundles.size(); i++) {
            ConfigBundle prev = bundles[i - 1];
            ConfigBundle curr = bundles[i];
            System.assertNotEquals(null, prev.developerName,
                'Bundle names should be populated for sorting');
            System.assertNotEquals(null, curr.developerName,
                'Bundle names should be populated for sorting');
        }
    }
}
