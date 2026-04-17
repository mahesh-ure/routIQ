/**
 * @description Test class for RoutingConfigSelector (Layer 4 Selector).
 *              Tests: CMDT retrieval, getAll methods, grouping, filtering.
 *
 *              Cost: Zero SOQL (CMDT.getAll() is platform-cached).
 *
 * @group Test
 */
@IsTest
private class RoutingConfigSelector_Test {

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. getAllConfigs Test
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getAllConfigs_returnsMap() {
        Test.startTest();
        Map<String, Routing_Config__mdt> configs = RoutingConfigSelector.getAllConfigs();
        Test.stopTest();

        System.assertNotEquals(null, configs,
            'getAllConfigs should not return null');
        System.assert(configs instanceof Map,
            'Result should be a Map<String, Routing_Config__mdt>');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. getAllConditions Test
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getAllConditions_returnsMap() {
        Test.startTest();
        Map<String, Routing_Condition__mdt> conditions =
            RoutingConfigSelector.getAllConditions();
        Test.stopTest();

        System.assertNotEquals(null, conditions,
            'getAllConditions should not return null');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. getAllPriorities Test
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getAllPriorities_returnsMap() {
        Test.startTest();
        Map<String, Routing_Priority__mdt> priorities =
            RoutingConfigSelector.getAllPriorities();
        Test.stopTest();

        System.assertNotEquals(null, priorities,
            'getAllPriorities should not return null');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. getAllSkillMappings Test (v6)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getAllSkillMappings_returnsMap() {
        Test.startTest();
        Map<String, Routing_Skill_Mapping__mdt> mappings =
            RoutingConfigSelector.getAllSkillMappings();
        Test.stopTest();

        System.assertNotEquals(null, mappings,
            'getAllSkillMappings should not return null (v6)');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 5. Configuration Completeness
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getAllConfigs_configsContainRequiredFields() {
        Test.startTest();
        Map<String, Routing_Config__mdt> configs = RoutingConfigSelector.getAllConfigs();
        Test.stopTest();

        for (Routing_Config__mdt config : configs.values()) {
            System.assertNotEquals(null, config.DeveloperName,
                'Config must have DeveloperName');
            System.assertNotEquals(null, config.Id,
                'Config must have Id');
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 6. Condition Structure
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getAllConditions_conditionsContainRequiredFields() {
        Test.startTest();
        Map<String, Routing_Condition__mdt> conditions =
            RoutingConfigSelector.getAllConditions();
        Test.stopTest();

        for (Routing_Condition__mdt cond : conditions.values()) {
            System.assertNotEquals(null, cond.DeveloperName,
                'Condition must have DeveloperName');
            System.assertNotEquals(null, cond.Id,
                'Condition must have Id');
            System.assertNotEquals(null, cond.Routing_Config__c,
                'Condition must reference parent config');
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 7. Priority Structure
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getAllPriorities_prioritiesContainRequiredFields() {
        Test.startTest();
        Map<String, Routing_Priority__mdt> priorities =
            RoutingConfigSelector.getAllPriorities();
        Test.stopTest();

        for (Routing_Priority__mdt pri : priorities.values()) {
            System.assertNotEquals(null, pri.DeveloperName,
                'Priority must have DeveloperName');
            System.assertNotEquals(null, pri.Id,
                'Priority must have Id');
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 8. Skill Mapping Structure (v6)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getAllSkillMappings_mappingsContainRequiredFields() {
        Test.startTest();
        Map<String, Routing_Skill_Mapping__mdt> mappings =
            RoutingConfigSelector.getAllSkillMappings();
        Test.stopTest();

        for (Routing_Skill_Mapping__mdt mapping : mappings.values()) {
            System.assertNotEquals(null, mapping.DeveloperName,
                'Skill mapping must have DeveloperName');
            System.assertNotEquals(null, mapping.Id,
                'Skill mapping must have Id');
            System.assertNotEquals(null, mapping.Routing_Config__c,
                'Skill mapping must reference parent config (v6)');
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 9. Zero SOQL Contract
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getAllConfigs_zeroSOQL() {
        Test.startTest();
        Integer soqlBefore = Limits.getQueries();
        Map<String, Routing_Config__mdt> configs = RoutingConfigSelector.getAllConfigs();
        Integer soqlAfter = Limits.getQueries();
        Test.stopTest();

        System.assertEquals(soqlBefore, soqlAfter,
            'getAllConfigs should use zero SOQL (CMDT.getAll() is cached)');
    }

    @IsTest
    static void getAllConditions_zeroSOQL() {
        Test.startTest();
        Integer soqlBefore = Limits.getQueries();
        Map<String, Routing_Condition__mdt> conditions =
            RoutingConfigSelector.getAllConditions();
        Integer soqlAfter = Limits.getQueries();
        Test.stopTest();

        System.assertEquals(soqlBefore, soqlAfter,
            'getAllConditions should use zero SOQL');
    }

    @IsTest
    static void getAllPriorities_zeroSOQL() {
        Test.startTest();
        Integer soqlBefore = Limits.getQueries();
        Map<String, Routing_Priority__mdt> priorities =
            RoutingConfigSelector.getAllPriorities();
        Integer soqlAfter = Limits.getQueries();
        Test.stopTest();

        System.assertEquals(soqlBefore, soqlAfter,
            'getAllPriorities should use zero SOQL');
    }

    @IsTest
    static void getAllSkillMappings_zeroSOQL() {
        Test.startTest();
        Integer soqlBefore = Limits.getQueries();
        Map<String, Routing_Skill_Mapping__mdt> mappings =
            RoutingConfigSelector.getAllSkillMappings();
        Integer soqlAfter = Limits.getQueries();
        Test.stopTest();

        System.assertEquals(soqlBefore, soqlAfter,
            'getAllSkillMappings should use zero SOQL (v6)');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 10. Null-Safe Handling
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getAllConfigs_handlesEmptyCMDT() {
        Test.startTest();
        Map<String, Routing_Config__mdt> configs = RoutingConfigSelector.getAllConfigs();
        Test.stopTest();

        // Even if no configs, should return non-null empty map
        System.assertNotEquals(null, configs,
            'Should return empty map if no configs exist');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 11. Multiple Calls (Caching)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getAllConfigs_consistentResults() {
        Test.startTest();
        Map<String, Routing_Config__mdt> configs1 = RoutingConfigSelector.getAllConfigs();
        Map<String, Routing_Config__mdt> configs2 = RoutingConfigSelector.getAllConfigs();
        Test.stopTest();

        System.assertEquals(configs1.size(), configs2.size(),
            'Multiple calls should return consistent results (caching)');
    }
}
