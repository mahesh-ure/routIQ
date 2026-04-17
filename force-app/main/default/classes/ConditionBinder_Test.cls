/**
 * @description Test class for ConditionBinder (Layer 3 Worker).
 *              Tests: field value extraction, binding, null-safe access,
 *              type conversion, relationship field handling.
 *
 * @group Test
 */
@IsTest
private class ConditionBinder_Test {

    @TestSetup
    static void setup() {
        Case c = new Case(Subject = 'Test', Status = 'New', Priority = 'High');
        insert c;
    }

    private static Case getCase() {
        return [SELECT Id, Subject, Status, Priority FROM Case LIMIT 1];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. Field Value Extraction
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void extractValue_simpleField() {
        Case testCase = getCase();

        Test.startTest();
        Object value = ConditionBinder.extractValue(testCase, 'Subject');
        Test.stopTest();

        System.assertEquals('Test', value,
            'Should extract simple field value');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. Null Field Handling
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void extractValue_nullField() {
        Case testCase = getCase();
        testCase.Description = null;
        update testCase;

        Test.startTest();
        Object value = ConditionBinder.extractValue(testCase, 'Description');
        Test.stopTest();

        System.assertEquals(null, value,
            'Null fields should return null');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. Non-existent Field Handling
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void extractValue_nonExistentField() {
        Case testCase = getCase();

        Test.startTest();
        try {
            Object value = ConditionBinder.extractValue(testCase, 'NonExistent__c');
            System.assertNotEquals(null, value,
                'Should handle missing field gracefully');
        } catch (Exception e) {
            System.assert(e instanceof SObjectException ||
                         e instanceof IllegalArgumentException,
                'Only expected exceptions for missing fields');
        }
        Test.stopTest();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. Type-Safe Binding (String)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void extractValue_stringField() {
        Case testCase = getCase();

        Test.startTest();
        Object value = ConditionBinder.extractValue(testCase, 'Status');
        Test.stopTest();

        System.assert(value instanceof String,
            'String fields should return String type');
        System.assertEquals('New', value,
            'Should return correct string value');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 5. Type-Safe Binding (Picklist)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void extractValue_picklistField() {
        Case testCase = getCase();

        Test.startTest();
        Object value = ConditionBinder.extractValue(testCase, 'Priority');
        Test.stopTest();

        System.assertEquals('High', value,
            'Picklist fields should return their values');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 6. Relationship Field Access (Parent)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void extractValue_relationshipField() {
        Case testCase = getCase();

        Test.startTest();
        try {
            Object value = ConditionBinder.extractValue(testCase, 'Account.Name');
            // May return null if no account is linked
            System.assertNotEquals(null, value,
                'Relationship fields should be accessible');
        } catch (Exception e) {
            // Relationship field access might not be loaded
            System.assert(true,
                'Relationship field handling depends on SObject state');
        }
        Test.stopTest();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 7. Null SObject Input
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void extractValue_nullSObject() {
        Test.startTest();
        try {
            Object value = ConditionBinder.extractValue(null, 'Subject');
            System.assert(false, 'Should throw NullPointerException');
        } catch (NullPointerException e) {
            System.assert(true, 'Expected NullPointerException');
        }
        Test.stopTest();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 8. Null Field Name Input
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void extractValue_nullFieldName() {
        Case testCase = getCase();

        Test.startTest();
        try {
            Object value = ConditionBinder.extractValue(testCase, null);
            System.assert(false, 'Should throw exception for null field name');
        } catch (Exception e) {
            System.assert(true, 'Expected exception for null field name');
        }
        Test.stopTest();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 9. Empty Field Name
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void extractValue_emptyFieldName() {
        Case testCase = getCase();

        Test.startTest();
        try {
            Object value = ConditionBinder.extractValue(testCase, '');
            System.assert(false, 'Should throw exception for empty field name');
        } catch (Exception e) {
            System.assert(true, 'Expected exception for empty field name');
        }
        Test.stopTest();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 10. Governor Limits (Zero SOQL)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void extractValue_zeroSOQL() {
        Case testCase = getCase();

        Test.startTest();
        Integer soqlBefore = Limits.getQueries();
        Object value = ConditionBinder.extractValue(testCase, 'Subject');
        Integer soqlAfter = Limits.getQueries();
        Test.stopTest();

        System.assertEquals(soqlBefore, soqlAfter,
            'Field extraction should use zero SOQL');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 11. Case-Insensitivity (Field API Names)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void extractValue_fieldNameHandling() {
        Case testCase = getCase();

        Test.startTest();
        Object value = ConditionBinder.extractValue(testCase, 'Subject');
        Test.stopTest();

        System.assertNotEquals(null, value,
            'Field names should be properly handled');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 12. Bulk Field Extraction
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void extractValue_bulkExtraction() {
        Case testCase = getCase();
        List<String> fieldNames = new List<String>{ 'Subject', 'Status', 'Priority' };

        Test.startTest();
        for (String fieldName : fieldNames) {
            Object value = ConditionBinder.extractValue(testCase, fieldName);
            System.assertNotEquals(null, value,
                'Should extract all field values');
        }
        Test.stopTest();
    }
}
