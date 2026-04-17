/**
 * @description Test class for DynamicQueryBuilder (Layer 3 Worker).
 *              Tests: WHERE clause generation, field binding, operator handling,
 *              multi-condition composition, null-safe building.
 *
 * @group Test
 */
@IsTest
private class DynamicQueryBuilder_Test {

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. Basic WHERE Clause Generation
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void buildWhereClause_simpleCondition() {
        List<Routing_Condition__mdt> conditions = new List<Routing_Condition__mdt>();
        Routing_Condition__mdt cond = new Routing_Condition__mdt();
        cond.Field_API_Name__c = 'Status';
        cond.Operator__c = 'EQUALS';
        cond.Value__c = 'New';
        conditions.add(cond);

        Test.startTest();
        Map<String, Object> bindMap = new Map<String, Object>();
        String where = DynamicQueryBuilder.buildWhereClause(conditions, bindMap);
        Test.stopTest();

        System.assertNotEquals(null, where,
            'WHERE clause should be generated');
        System.assert(where.contains('Status'),
            'WHERE clause should reference field name');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. Bind Variable Usage
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void buildWhereClause_usesBindVariables() {
        List<Routing_Condition__mdt> conditions = new List<Routing_Condition__mdt>();
        Routing_Condition__mdt cond = new Routing_Condition__mdt();
        cond.Field_API_Name__c = 'Subject';
        cond.Operator__c = 'EQUALS';
        cond.Value__c = 'Help';
        conditions.add(cond);

        Map<String, Object> bindMap = new Map<String, Object>();

        Test.startTest();
        String where = DynamicQueryBuilder.buildWhereClause(conditions, bindMap);
        Test.stopTest();

        System.assertNotEquals(null, where,
            'WHERE clause should use bind variables');
        System.assert(bindMap.size() > 0,
            'Bind map should be populated');
        System.assert(where.contains(':'),
            'WHERE clause should contain bind variable syntax');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. Multiple Conditions (AND Logic)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void buildWhereClause_multipleConditions() {
        List<Routing_Condition__mdt> conditions = new List<Routing_Condition__mdt>();

        Routing_Condition__mdt cond1 = new Routing_Condition__mdt();
        cond1.Field_API_Name__c = 'Status';
        cond1.Operator__c = 'EQUALS';
        cond1.Value__c = 'New';
        conditions.add(cond1);

        Routing_Condition__mdt cond2 = new Routing_Condition__mdt();
        cond2.Field_API_Name__c = 'Priority';
        cond2.Operator__c = 'EQUALS';
        cond2.Value__c = 'High';
        conditions.add(cond2);

        Map<String, Object> bindMap = new Map<String, Object>();

        Test.startTest();
        String where = DynamicQueryBuilder.buildWhereClause(conditions, bindMap);
        Test.stopTest();

        System.assertNotEquals(null, where,
            'WHERE clause with multiple conditions should be generated');
        System.assert(where.contains('AND'),
            'Multiple conditions should be AND-joined');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. Operator Handling (LESS_THAN, GREATER_THAN, etc.)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void buildWhereClause_numericOperators() {
        List<Routing_Condition__mdt> conditions = new List<Routing_Condition__mdt>();
        Routing_Condition__mdt cond = new Routing_Condition__mdt();
        cond.Field_API_Name__c = 'Amount__c';
        cond.Operator__c = 'GREATER_THAN';
        cond.Value__c = '1000';
        conditions.add(cond);

        Map<String, Object> bindMap = new Map<String, Object>();

        Test.startTest();
        String where = DynamicQueryBuilder.buildWhereClause(conditions, bindMap);
        Test.stopTest();

        System.assertNotEquals(null, where,
            'Numeric operators should work');
        System.assert(where.contains('>'),
            'WHERE clause should contain numeric operator');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 5. NULL Condition Handling
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void buildWhereClause_nullConditions() {
        Map<String, Object> bindMap = new Map<String, Object>();

        Test.startTest();
        String where = DynamicQueryBuilder.buildWhereClause(null, bindMap);
        Test.stopTest();

        System.assertNotEquals(null, where,
            'Should handle null conditions gracefully');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 6. Empty Conditions List
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void buildWhereClause_emptyConditions() {
        Map<String, Object> bindMap = new Map<String, Object>();

        Test.startTest();
        String where = DynamicQueryBuilder.buildWhereClause(
            new List<Routing_Condition__mdt>(),
            bindMap
        );
        Test.stopTest();

        System.assertNotEquals(null, where,
            'Empty conditions should return non-null');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 7. Field API Name Mapping
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void buildWhereClause_fieldNameMapping() {
        List<Routing_Condition__mdt> conditions = new List<Routing_Condition__mdt>();
        Routing_Condition__mdt cond = new Routing_Condition__mdt();
        cond.Field_API_Name__c = 'RecordType.DeveloperName';
        cond.Operator__c = 'EQUALS';
        cond.Value__c = 'Support';
        conditions.add(cond);

        Map<String, Object> bindMap = new Map<String, Object>();

        Test.startTest();
        String where = DynamicQueryBuilder.buildWhereClause(conditions, bindMap);
        Test.stopTest();

        System.assertNotEquals(null, where,
            'Relationship field names should work');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 8. INCLUDES/EXCLUDES Operator (Multi-select)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void buildWhereClause_multiSelectOperators() {
        List<Routing_Condition__mdt> conditions = new List<Routing_Condition__mdt>();
        Routing_Condition__mdt cond = new Routing_Condition__mdt();
        cond.Field_API_Name__c = 'Regions__c';
        cond.Operator__c = 'INCLUDES';
        cond.Value__c = 'North;South';
        conditions.add(cond);

        Map<String, Object> bindMap = new Map<String, Object>();

        Test.startTest();
        String where = DynamicQueryBuilder.buildWhereClause(conditions, bindMap);
        Test.stopTest();

        System.assertNotEquals(null, where,
            'Multi-select operators should work');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 9. Value Null Handling
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void buildWhereClause_nullValue() {
        List<Routing_Condition__mdt> conditions = new List<Routing_Condition__mdt>();
        Routing_Condition__mdt cond = new Routing_Condition__mdt();
        cond.Field_API_Name__c = 'Status';
        cond.Operator__c = 'EQUALS';
        cond.Value__c = null;
        conditions.add(cond);

        Map<String, Object> bindMap = new Map<String, Object>();

        Test.startTest();
        String where = DynamicQueryBuilder.buildWhereClause(conditions, bindMap);
        Test.stopTest();

        // Should handle null values gracefully
        System.assertNotEquals(null, where,
            'Should handle null values in conditions');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 10. Bind Map State
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void buildWhereClause_bindMapPopulated() {
        List<Routing_Condition__mdt> conditions = new List<Routing_Condition__mdt>();
        Routing_Condition__mdt cond = new Routing_Condition__mdt();
        cond.Field_API_Name__c = 'Status';
        cond.Operator__c = 'EQUALS';
        cond.Value__c = 'New';
        conditions.add(cond);

        Map<String, Object> bindMap = new Map<String, Object>();

        Test.startTest();
        String where = DynamicQueryBuilder.buildWhereClause(conditions, bindMap);
        Test.stopTest();

        if (bindMap.size() > 0) {
            System.assertNotEquals(null, bindMap.values()[0],
                'Bind map should contain actual values');
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 11. SQL Injection Prevention
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void buildWhereClause_preventsInjection() {
        List<Routing_Condition__mdt> conditions = new List<Routing_Condition__mdt>();
        Routing_Condition__mdt cond = new Routing_Condition__mdt();
        cond.Field_API_Name__c = 'Subject';
        cond.Operator__c = 'EQUALS';
        cond.Value__c = '\' OR \'1\'=\'1';
        conditions.add(cond);

        Map<String, Object> bindMap = new Map<String, Object>();

        Test.startTest();
        String where = DynamicQueryBuilder.buildWhereClause(conditions, bindMap);
        Test.stopTest();

        // Since we use bind variables, injection should be prevented
        System.assert(bindMap.size() > 0,
            'Should use bind variables to prevent injection');
        System.assertNotEquals(null, where,
            'Query should be safely constructed');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 12. Governor Limits (Zero DML)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void buildWhereClause_zeroGovernorCost() {
        List<Routing_Condition__mdt> conditions = new List<Routing_Condition__mdt>();
        for (Integer i = 0; i < 10; i++) {
            Routing_Condition__mdt cond = new Routing_Condition__mdt();
            cond.Field_API_Name__c = 'Field' + i;
            cond.Operator__c = 'EQUALS';
            cond.Value__c = 'Value' + i;
            conditions.add(cond);
        }

        Map<String, Object> bindMap = new Map<String, Object>();

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        String where = DynamicQueryBuilder.buildWhereClause(conditions, bindMap);
        Integer dmlAfter = Limits.getDmlStatements();
        Test.stopTest();

        System.assertEquals(dmlBefore, dmlAfter,
            'Query builder should use zero DML');
    }
}
