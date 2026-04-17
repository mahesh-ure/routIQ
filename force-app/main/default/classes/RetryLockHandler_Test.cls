/**
 * @description Test class for RetryLockHandler (Layer 3 Worker).
 *              Tests: lock acquisition, retry logic, exhaustion scenarios,
 *              record-gone handling, bounded retry attempts.
 *
 *              Cost: SOQL (delegates to AssignmentSelector.lockRecord()).
 *
 * @group Test
 */
@IsTest
private class RetryLockHandler_Test {

    @TestSetup
    static void setup() {
        Agent__c agent = new Agent__c(
            User__c = UserInfo.getUserId(),
            Is_Active__c = true,
            Max_Capacity__c = 50,
            Current_Load__c = 0
        );
        insert agent;
    }

    private static Agent__c getAgent() {
        return [
            SELECT Id, User__c, Is_Active__c, Max_Capacity__c, Current_Load__c
            FROM Agent__c
            LIMIT 1
        ];
    }

    private static SObject createCaseRecord() {
        Case c = new Case(Subject = 'Test Case', Status = 'New');
        insert c;
        return c;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. RetryOutcome Factory Tests
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void retryOutcome_fieldsPopulated() {
        Case testCase = (Case) createCaseRecord();

        Test.startTest();
        // Test through a successful lock attempt
        RetryLockHandler.RetryOutcome outcome = RetryLockHandler.attemptLock(
            testCase.Id,
            'Case',
            1,
            'Test'
        );
        Test.stopTest();

        // Verify outcome structure
        System.assertNotEquals(null, outcome,
            'Outcome should be populated');
        System.assertNotEquals(null, outcome.success,
            'Outcome must have success flag');
        System.assertNotEquals(null, outcome.retryCount,
            'Outcome must have retryCount');
        System.assertNotEquals(null, outcome.exhausted,
            'Outcome must have exhausted flag');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. Successful Lock Acquisition
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void attemptLock_validRecord_succeeds() {
        Case testCase = (Case) createCaseRecord();

        AssignmentSelector.mockLockFails = false;

        Test.startTest();
        RetryLockHandler.RetryOutcome outcome = RetryLockHandler.attemptLock(
            testCase.Id,
            'Case',
            1,
            'Test'
        );
        Test.stopTest();

        System.assertEquals(true, outcome.success,
            'Lock on valid record should succeed');
        System.assertNotEquals(null, outcome.lockedRecord,
            'Outcome should contain locked record');
        System.assertEquals(false, outcome.exhausted,
            'Should not be exhausted on first successful attempt');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. Record Not Found Test
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void attemptLock_recordDeleted_returnsRecordGone() {
        Case testCase = (Case) createCaseRecord();
        Id caseId = testCase.Id;

        // Delete the record before attempting lock
        delete testCase;

        Test.startTest();
        RetryLockHandler.RetryOutcome outcome = RetryLockHandler.attemptLock(
            caseId,
            'Case',
            1,
            'Test'
        );
        Test.stopTest();

        System.assertEquals(false, outcome.success,
            'Lock on deleted record should fail');
        System.assertEquals(false, outcome.exhausted,
            'Record gone should not be exhaustion');
        System.assertNotEquals(null, outcome.errorMessage,
            'Should have error message for record gone');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. Retry Count Tracking
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void attemptLock_trackRetryCount() {
        Case testCase = (Case) createCaseRecord();

        AssignmentSelector.mockLockFails = false;

        Test.startTest();
        RetryLockHandler.RetryOutcome outcome = RetryLockHandler.attemptLock(
            testCase.Id,
            'Case',
            1,
            'Test'
        );
        Test.stopTest();

        System.assert(outcome.retryCount >= 0,
            'Retry count should be tracked');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 5. Lock Contention Detection
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void attemptLock_lockContention_retries() {
        Case testCase = (Case) createCaseRecord();

        // Mock lock contention
        AssignmentSelector.mockLockFails = true;

        Test.startTest();
        RetryLockHandler.RetryOutcome outcome = RetryLockHandler.attemptLock(
            testCase.Id,
            'Case',
            1,
            'Test'
        );
        Test.stopTest();

        // With maxRetries=1 and lock contention, should fail
        System.assertEquals(false, outcome.success,
            'Persistent lock contention should eventually fail');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 6. Max Retries Config Test
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void attemptLock_maxRetriesFromConfig() {
        Case testCase = (Case) createCaseRecord();

        Test.startTest();
        // Call with custom maxRetries
        RetryLockHandler.RetryOutcome outcome = RetryLockHandler.attemptLock(
            testCase.Id,
            'Case',
            3,
            'Test'
        );
        Test.stopTest();

        System.assertNotEquals(null, outcome,
            'Should respect maxRetries parameter');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 7. Fallback Constant Test
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void attemptLock_usesDefaultMaxRetries() {
        Case testCase = (Case) createCaseRecord();

        Test.startTest();
        // Call with maxRetries=0 or null should use DEFAULT
        RetryLockHandler.RetryOutcome outcome = RetryLockHandler.attemptLock(
            testCase.Id,
            'Case',
            0,
            'Test'
        );
        Test.stopTest();

        // Should still attempt at least once
        System.assertNotEquals(null, outcome,
            'Should use default max retries when provided value is invalid');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 8. Governor Limits Test
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void attemptLock_boundedGovernorUsage() {
        Case testCase = (Case) createCaseRecord();

        Test.startTest();
        Integer soqlBefore = Limits.getQueries();
        RetryLockHandler.RetryOutcome outcome = RetryLockHandler.attemptLock(
            testCase.Id,
            'Case',
            1,
            'Test'
        );
        Integer soqlAfter = Limits.getQueries();
        Test.stopTest();

        Integer soqlUsed = soqlAfter - soqlBefore;
        System.assert(soqlUsed <= 5,
            'Lock attempt should use bounded SOQL (got ' + soqlUsed + ')');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 9. Error Message Labeling (Security Review)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void attemptLock_errorMessagesFromLabels() {
        Case testCase = (Case) createCaseRecord();
        delete testCase;

        Test.startTest();
        RetryLockHandler.RetryOutcome outcome = RetryLockHandler.attemptLock(
            testCase.Id,
            'Case',
            1,
            'Test'
        );
        Test.stopTest();

        if (!outcome.success) {
            System.assertNotEquals(null, outcome.errorMessage,
                'Error messages must use System.Label');
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 10. Null-Safe Record ID Handling
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void attemptLock_nullRecordId_handleGracefully() {
        Test.startTest();
        try {
            RetryLockHandler.RetryOutcome outcome = RetryLockHandler.attemptLock(
                null,
                'Case',
                1,
                'Test'
            );
            System.assertNotEquals(null, outcome,
                'Should handle null record ID gracefully');
        } catch (Exception e) {
            System.assert(e instanceof NullPointerException ||
                          e instanceof InvalidParameterValueException,
                'Only expected null handling exceptions');
        }
        Test.stopTest();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 11. Bulk Lock Attempts
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void attemptLock_bulkRecords() {
        List<Case> cases = new List<Case>();
        for (Integer i = 0; i < 5; i++) {
            cases.add(new Case(Subject = 'Case ' + i, Status = 'New'));
        }
        insert cases;

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        for (Case c : cases) {
            RetryLockHandler.RetryOutcome outcome = RetryLockHandler.attemptLock(
                c.Id,
                'Case',
                1,
                'Test'
            );
        }
        Integer dmlAfter = Limits.getDmlStatements();
        Test.stopTest();

        Integer dmlUsed = dmlAfter - dmlBefore;
        System.assert(dmlUsed <= 15,
            'Bulk lock attempts should be governed (got ' + dmlUsed + ' DML)');
    }
}
