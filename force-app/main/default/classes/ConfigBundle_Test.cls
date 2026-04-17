/**
 * @description Test class for ConfigBundle (Domain DTO).
 *              Tests: bundle structure, CMDT grouping, metadata access.
 *
 * @group Test
 */
@IsTest
private class ConfigBundle_Test {

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. Bundle Construction
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void construct_bundle() {
        Test.startTest();
        ConfigBundle bundle = new ConfigBundle();
        Test.stopTest();

        System.assertNotEquals(null, bundle,
            'ConfigBundle should be constructible');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. Developer Name Population
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void populate_developerName() {
        Test.startTest();
        ConfigBundle bundle = new ConfigBundle();
        bundle.developerName = 'Support_Standard';
        Test.stopTest();

        System.assertEquals('Support_Standard', bundle.developerName,
            'Developer name should be settable');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. Object API Name
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void populate_objectApiName() {
        Test.startTest();
        ConfigBundle bundle = new ConfigBundle();
        bundle.objectApiName = 'Case';
        Test.stopTest();

        System.assertEquals('Case', bundle.objectApiName,
            'Object API name should be settable');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. Active Status
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void populate_isActive() {
        Test.startTest();
        ConfigBundle bundle = new ConfigBundle();
        bundle.isActive = true;
        Test.stopTest();

        System.assertEquals(true, bundle.isActive,
            'Active status should be settable');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 5. Conditions List
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void populate_conditions() {
        Test.startTest();
        ConfigBundle bundle = new ConfigBundle();
        bundle.conditions = new List<Routing_Condition__mdt>();
        bundle.conditions.add(new Routing_Condition__mdt());
        Test.stopTest();

        System.assertEquals(1, bundle.conditions.size(),
            'Conditions list should be settable');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 6. Priorities List
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void populate_priorities() {
        Test.startTest();
        ConfigBundle bundle = new ConfigBundle();
        bundle.priorities = new List<Routing_Priority__mdt>();
        bundle.priorities.add(new Routing_Priority__mdt());
        Test.stopTest();

        System.assertEquals(1, bundle.priorities.size(),
            'Priorities list should be settable');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 7. Skill Mappings List (v6)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void populate_skillMappings() {
        Test.startTest();
        ConfigBundle bundle = new ConfigBundle();
        bundle.skillMappings = new List<Routing_Skill_Mapping__mdt>();
        bundle.skillMappings.add(new Routing_Skill_Mapping__mdt());
        Test.stopTest();

        System.assertEquals(1, bundle.skillMappings.size(),
            'Skill mappings list should be settable (v6)');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 8. Multiple Conditions
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void populate_multipleConditions() {
        Test.startTest();
        ConfigBundle bundle = new ConfigBundle();
        bundle.conditions = new List<Routing_Condition__mdt>();
        for (Integer i = 0; i < 5; i++) {
            bundle.conditions.add(new Routing_Condition__mdt());
        }
        Test.stopTest();

        System.assertEquals(5, bundle.conditions.size(),
            'Bundle should support multiple conditions');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 9. Null Fields
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void nullFields_optional() {
        Test.startTest();
        ConfigBundle bundle = new ConfigBundle();
        Test.stopTest();

        System.assertEquals(null, bundle.developerName,
            'Fields default to null');
        System.assertEquals(null, bundle.conditions,
            'Collections default to null');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 10. Bundle Completeness
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void completeBundle() {
        Test.startTest();
        ConfigBundle bundle = new ConfigBundle();
        bundle.developerName = 'Support_Standard';
        bundle.objectApiName = 'Case';
        bundle.isActive = true;
        bundle.conditions = new List<Routing_Condition__mdt>();
        bundle.priorities = new List<Routing_Priority__mdt>();
        bundle.skillMappings = new List<Routing_Skill_Mapping__mdt>();
        Test.stopTest();

        System.assertNotEquals(null, bundle.developerName,
            'Complete bundle should have all fields set');
        System.assertNotEquals(null, bundle.conditions,
            'Complete bundle should have all collections');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 11. JSON Serialization
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void serialize_toJSON() {
        ConfigBundle bundle = new ConfigBundle();
        bundle.developerName = 'TestConfig';
        bundle.objectApiName = 'Case';
        bundle.isActive = true;
        bundle.conditions = new List<Routing_Condition__mdt>();
        bundle.priorities = new List<Routing_Priority__mdt>();
        bundle.skillMappings = new List<Routing_Skill_Mapping__mdt>();

        Test.startTest();
        String json = JSON.serialize(bundle);
        Test.stopTest();

        System.assertNotEquals(null, json,
            'Bundle should be JSON serializable');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 12. Inactive Bundle
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void populate_inactiveBundle() {
        Test.startTest();
        ConfigBundle bundle = new ConfigBundle();
        bundle.isActive = false;
        Test.stopTest();

        System.assertEquals(false, bundle.isActive,
            'Bundle can be inactive');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 13. Empty Collections
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void emptyCollections() {
        Test.startTest();
        ConfigBundle bundle = new ConfigBundle();
        bundle.conditions = new List<Routing_Condition__mdt>();
        bundle.priorities = new List<Routing_Priority__mdt>();
        bundle.skillMappings = new List<Routing_Skill_Mapping__mdt>();
        Test.stopTest();

        System.assertEquals(0, bundle.conditions.size(),
            'Collections can be empty');
        System.assertEquals(0, bundle.priorities.size(),
            'Collections can be empty');
        System.assertEquals(0, bundle.skillMappings.size(),
            'Collections can be empty');
    }
}
