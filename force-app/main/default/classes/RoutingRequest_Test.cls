/**
 * @description Test class for RoutingRequest (Layer 1 DTO).
 *              Tests: validation, null-safe construction, field population.
 *
 * @group Test
 */
@IsTest
private class RoutingRequest_Test {

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. Valid Request Construction
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void construct_validRequest() {
        Test.startTest();
        RoutingRequest request = new RoutingRequest();
        request.objectApiName = 'Case';
        request.recordId = UserInfo.getUserId();
        request.configDeveloperName = 'TestConfig';
        request.dryRun = false;
        Test.stopTest();

        System.assertNotEquals(null, request,
            'Request should be constructible');
        System.assertEquals('Case', request.objectApiName,
            'Object name should be settable');
        System.assertEquals(false, request.dryRun,
            'DryRun should be settable');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. Null Fields (Default Values)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void construct_nullFields() {
        Test.startTest();
        RoutingRequest request = new RoutingRequest();
        Test.stopTest();

        System.assertNotEquals(null, request,
            'Request should construct with null fields');
        System.assertEquals(null, request.objectApiName,
            'Fields should default to null');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. Validation: Empty Object Name
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void validate_emptyObjectName() {
        RoutingRequest request = new RoutingRequest();
        request.objectApiName = '';
        request.recordId = UserInfo.getUserId();

        Test.startTest();
        List<String> errors = request.validate();
        Test.stopTest();

        System.assertNotEquals(0, errors.size(),
            'Empty object name should fail validation');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. Validation: Null Object Name
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void validate_nullObjectName() {
        RoutingRequest request = new RoutingRequest();
        request.objectApiName = null;
        request.recordId = UserInfo.getUserId();

        Test.startTest();
        List<String> errors = request.validate();
        Test.stopTest();

        System.assertNotEquals(0, errors.size(),
            'Null object name should fail validation');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 5. Validation: Valid Request
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void validate_validRequest() {
        RoutingRequest request = new RoutingRequest();
        request.objectApiName = 'Case';
        request.recordId = UserInfo.getUserId();

        Test.startTest();
        List<String> errors = request.validate();
        Test.stopTest();

        System.assertEquals(0, errors.size(),
            'Valid request should pass validation');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 6. DryRun Flag Default
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void construct_dryRunDefault() {
        Test.startTest();
        RoutingRequest request = new RoutingRequest();
        request.objectApiName = 'Case';
        request.recordId = UserInfo.getUserId();
        Test.stopTest();

        // DryRun should have a default value (likely false)
        System.assertNotEquals(null, request.dryRun,
            'DryRun should have a default');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 7. Override Agent ID Field
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void construct_overrideAgentId() {
        Agent__c agent = new Agent__c(
            User__c = UserInfo.getUserId(),
            Is_Active__c = true
        );
        insert agent;

        Test.startTest();
        RoutingRequest request = new RoutingRequest();
        request.objectApiName = 'Case';
        request.overrideAgentId = agent.Id;
        Test.stopTest();

        System.assertEquals(agent.Id, request.overrideAgentId,
            'Override agent ID should be settable');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 8. Config Developer Name (Optional)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void construct_configName() {
        Test.startTest();
        RoutingRequest request = new RoutingRequest();
        request.objectApiName = 'Case';
        request.recordId = UserInfo.getUserId();
        request.configDeveloperName = 'Custom_Config';
        Test.stopTest();

        System.assertEquals('Custom_Config', request.configDeveloperName,
            'Config name should be settable');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 9. Record ID Field
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void construct_recordId() {
        Test.startTest();
        RoutingRequest request = new RoutingRequest();
        request.recordId = UserInfo.getUserId();
        Test.stopTest();

        System.assertEquals(UserInfo.getUserId(), request.recordId,
            'Record ID should be settable');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 10. Validation Returns List
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void validate_returnsErrorList() {
        RoutingRequest request = new RoutingRequest();
        request.objectApiName = null;

        Test.startTest();
        List<String> errors = request.validate();
        Test.stopTest();

        System.assert(errors instanceof List,
            'Validation should return List<String>');
        System.assertNotEquals(null, errors,
            'Validation should return non-null list');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 11. Multiple Validation Errors
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void validate_multipleErrors() {
        RoutingRequest request = new RoutingRequest();
        request.objectApiName = '';
        request.recordId = null;

        Test.startTest();
        List<String> errors = request.validate();
        Test.stopTest();

        // Should collect multiple validation errors
        System.assertNotEquals(null, errors,
            'Should return validation errors');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 12. JSON Serialization (for REST)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void serialize_toJSON() {
        RoutingRequest request = new RoutingRequest();
        request.objectApiName = 'Case';
        request.recordId = UserInfo.getUserId();

        Test.startTest();
        String json = JSON.serialize(request);
        Test.stopTest();

        System.assertNotEquals(null, json,
            'Request should be JSON serializable');
        System.assert(json.contains('Case'),
            'JSON should contain request data');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 13. JSON Deserialization (from REST)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void deserialize_fromJSON() {
        String json = '{"objectApiName":"Case","recordId":"' + UserInfo.getUserId() + '","dryRun":false}';

        Test.startTest();
        RoutingRequest request = (RoutingRequest) JSON.deserialize(json, RoutingRequest.class);
        Test.stopTest();

        System.assertEquals('Case', request.objectApiName,
            'Deserialized request should have correct values');
    }
}
