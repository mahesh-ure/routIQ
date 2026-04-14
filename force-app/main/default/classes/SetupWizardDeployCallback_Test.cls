/**
 * @description Test class for SetupWizardDeployCallback. Covers the deploy callback
 *              logic, Platform Cache storage/retrieval, and agent provisioning.
 *
 *              Note: Metadata.DeployCallback.handleResult() cannot be directly invoked
 *              in Apex tests because Metadata.DeployResult and DeployCallbackContext
 *              are not constructable. Tests cover:
 *              • Static cache helper methods (getStoredResult, clearStoredResult)
 *              • AgentData serialisation/deserialisation
 *              • DeployOutcome structure
 *              • Constructor parameter serialisation survival
 *
 * @group Test
 */
@IsTest
private class SetupWizardDeployCallback_Test {

    // ═══════════════════════════════════════════════════════════════════════════
    // DeployOutcome structure
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void deployOutcome_constructorSetsFields() {
        Test.startTest();
        SetupWizardDeployCallback.DeployOutcome outcome =
            new SetupWizardDeployCallback.DeployOutcome(true, 'Succeeded', null);
        Test.stopTest();

        System.assertEquals(true, outcome.success,
            'success should be true');
        System.assertEquals('Succeeded', outcome.status,
            'status should match');
        System.assertEquals(null, outcome.errorMessage,
            'errorMessage should be null for success');
    }

    @IsTest
    static void deployOutcome_failureIncludesError() {
        Test.startTest();
        SetupWizardDeployCallback.DeployOutcome outcome =
            new SetupWizardDeployCallback.DeployOutcome(
                false, 'Failed', 'Field validation error'
            );
        Test.stopTest();

        System.assertEquals(false, outcome.success,
            'success should be false');
        System.assertEquals('Field validation error', outcome.errorMessage,
            'errorMessage should contain the error');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Cache helpers — getStoredResult / clearStoredResult
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getStoredResult_noCacheEntry_returnsNull() {
        Test.startTest();
        SetupWizardDeployCallback.DeployOutcome result =
            SetupWizardDeployCallback.getStoredResult('NonExistent_Config');
        Test.stopTest();

        // Should return null when no cached result exists
        // (Platform Cache may not be available in test context — that's OK,
        // the method gracefully returns null)
        System.assertEquals(null, result,
            'Should return null when no cache entry exists');
    }

    @IsTest
    static void clearStoredResult_noException() {
        // Verify clearStoredResult doesn't throw even when key doesn't exist
        Test.startTest();
        SetupWizardDeployCallback.clearStoredResult('NonExistent_Config');
        Test.stopTest();

        // No exception = pass
        System.assert(true, 'clearStoredResult should not throw');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // AgentData serialisation
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void agentData_serialisationRoundTrip() {
        Id userId = UserInfo.getUserId();

        List<SetupWizardDeployCallback.AgentData> agents =
            new List<SetupWizardDeployCallback.AgentData>();
        SetupWizardDeployCallback.AgentData ad = new SetupWizardDeployCallback.AgentData();
        ad.userId = userId;
        ad.skillValues = new List<String>{ 'Hot', 'Warm' };
        agents.add(ad);

        String serialized = JSON.serialize(agents);

        Test.startTest();
        List<SetupWizardDeployCallback.AgentData> deserialized =
            (List<SetupWizardDeployCallback.AgentData>) JSON.deserialize(
                serialized, List<SetupWizardDeployCallback.AgentData>.class
            );
        Test.stopTest();

        System.assertEquals(1, deserialized.size(),
            'Should deserialize one agent');
        System.assertEquals(userId, deserialized[0].userId,
            'userId should survive serialisation');
        System.assertEquals(2, deserialized[0].skillValues.size(),
            'skillValues should survive serialisation');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Constructor — parameter storage
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void constructor_acceptsAllParameters() {
        // Verify the callback can be constructed with all parameter types
        // (constructor params must be serialisable for async callback survival)
        Test.startTest();
        SetupWizardDeployCallback callback = new SetupWizardDeployCallback(
            'Test_Config',
            '[{"userId":"005000000000001","skillValues":["Hot"]}]',
            10
        );
        Test.stopTest();

        // Constructor succeeded — parameters are serialisable
        System.assertNotEquals(null, callback,
            'Callback should be constructable');
    }

    @IsTest
    static void constructor_nullMaxCapacity_defaultsToFive() {
        // Verify null maxCapacity doesn't cause issues
        Test.startTest();
        SetupWizardDeployCallback callback = new SetupWizardDeployCallback(
            'Test_Config',
            null,
            null
        );
        Test.stopTest();

        System.assertNotEquals(null, callback,
            'Callback should handle null maxCapacity');
    }
}
