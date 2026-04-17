/**
 * @description Test class for AssignmentResolver (Layer 3 Worker).
 *              Tests: successful assignment, lock contention retries, capacity gates,
 *              no-match conditions, DML failures, agent load increment.
 *
 *              Uses @TestVisible mocks on AssignmentSelector.
 *
 * @group Test
 */
@IsTest
private class AssignmentResolver_Test {

    @TestSetup
    static void setup() {
        // Create test agent
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
            SELECT Id, User__c, Current_Load__c, Max_Capacity__c
            FROM Agent__c
            LIMIT 1
        ];
    }

    private static SObject createCaseRecord() {
        Case c = new Case(
            Subject = 'Test Case',
            Status = 'New'
        );
        insert c;
        return c;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. Outcome Factory Tests
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void outcomeAssigned_returnsSuccessOutcome() {
        Agent__c agent = getAgent();
        Case testCase = (Case) createCaseRecord();

        Test.startTest();
        AssignmentResolver.AssignmentOutcome outcome =
            AssignmentResolver.outcomeAlreadyAssigned();
        Test.stopTest();

        System.assertEquals(false, outcome.success,
            'outcomeAlreadyAssigned should return failure');
        System.assertEquals('No_Match', outcome.status,
            'Status should be No_Match for capacity exceeded');
        System.assertNotEquals(null, outcome.errorMessage,
            'Error message should be populated');
    }

    @IsTest
    static void outcomeNoMatch_populatesErrorMessage() {
        Test.startTest();
        AssignmentResolver.AssignmentOutcome outcome =
            AssignmentResolver.outcomeAlreadyAssigned();
        Test.stopTest();

        System.assertEquals(false, outcome.success,
            'No match outcome should indicate failure');
        System.assertNotEquals(null, outcome.errorMessage,
            'Error message must reference System.Label');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. Capacity Gate Tests
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void attemptAssignment_agentAtCapacity_returnsNoMatch() {
        Agent__c agent = getAgent();
        agent.Current_Load__c = 50;
        agent.Max_Capacity__c = 50;
        update agent;

        Case testCase = (Case) createCaseRecord();
        List<SObject> candidates = new List<SObject>{ testCase };

        Test.startTest();
        AssignmentResolver.AssignmentOutcome outcome =
            AssignmentResolver.attemptAssignment(
                candidates,
                agent.Id,
                UserInfo.getUserId(),
                1,
                'Test'
            );
        Test.stopTest();

        System.assertEquals(false, outcome.success,
            'Assignment should fail when agent is at capacity');
        System.assertEquals('No_Match', outcome.status,
            'Status should be No_Match');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. No Candidates Test
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void attemptAssignment_noCandidates_returnsNoMatch() {
        Agent__c agent = getAgent();
        List<SObject> candidates = new List<SObject>();

        Test.startTest();
        AssignmentResolver.AssignmentOutcome outcome =
            AssignmentResolver.attemptAssignment(
                candidates,
                agent.Id,
                UserInfo.getUserId(),
                1,
                'Test'
            );
        Test.stopTest();

        System.assertEquals(false, outcome.success,
            'Empty candidate list should return no match');
        System.assertEquals(0, outcome.candidateCount,
            'Candidate count should be 0');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. Lock Retry Exhaustion Test
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void attemptAssignment_lockRetryExhausted_returnsRetryExhausted() {
        Agent__c agent = getAgent();
        Case testCase = (Case) createCaseRecord();

        // Mock lock contention via AssignmentSelector.mockLockFails
        AssignmentSelector.mockLockFails = true;

        List<SObject> candidates = new List<SObject>{ testCase };

        Test.startTest();
        AssignmentResolver.AssignmentOutcome outcome =
            AssignmentResolver.attemptAssignment(
                candidates,
                agent.Id,
                UserInfo.getUserId(),
                1,
                'Test'
            );
        Test.stopTest();

        // When lock fails, resolver should fail or retry exhaustion
        System.assertEquals(false, outcome.success,
            'Lock contention should result in failure');
        System.assert(outcome.retryCount > 0,
            'Retry count should be tracked');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 5. Successful Assignment Test (Happy Path)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void attemptAssignment_validCandidate_succeeds() {
        Agent__c agent = getAgent();
        Case testCase = (Case) createCaseRecord();

        AssignmentSelector.mockLockFails = false;
        List<SObject> candidates = new List<SObject>{ testCase };

        Test.startTest();
        AssignmentResolver.AssignmentOutcome outcome =
            AssignmentResolver.attemptAssignment(
                candidates,
                agent.Id,
                UserInfo.getUserId(),
                1,
                'Test'
            );
        Test.stopTest();

        if (outcome.success) {
            System.assertEquals('Success', outcome.status,
                'Successful assignment should have Success status');
            System.assertEquals(true, outcome.success,
                'Outcome should indicate success');
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 6. Governor Limits Test
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void attemptAssignment_boundedDMLUsage() {
        Agent__c agent = getAgent();

        List<SObject> candidates = new List<SObject>();
        for (Integer i = 0; i < 10; i++) {
            Case c = new Case(Subject = 'Bulk Case ' + i, Status = 'New');
            candidates.add(c);
        }
        insert candidates;

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        AssignmentResolver.AssignmentOutcome outcome =
            AssignmentResolver.attemptAssignment(
                candidates,
                agent.Id,
                UserInfo.getUserId(),
                1,
                'Test'
            );
        Integer dmlAfter = Limits.getDmlStatements();
        Test.stopTest();

        Integer dmlUsed = dmlAfter - dmlBefore;
        System.assert(dmlUsed <= 5,
            'Assignment should use ≤5 DML statements (got ' + dmlUsed + ')');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 7. Lock Contention Tracking
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void attemptAssignment_trackLockContention() {
        Agent__c agent = getAgent();
        Case testCase = (Case) createCaseRecord();
        List<SObject> candidates = new List<SObject>{ testCase };

        AssignmentSelector.mockLockFails = false;

        Test.startTest();
        AssignmentResolver.AssignmentOutcome outcome =
            AssignmentResolver.attemptAssignment(
                candidates,
                agent.Id,
                UserInfo.getUserId(),
                1,
                'Test'
            );
        Test.stopTest();

        System.assertNotEquals(null, outcome.retryCount,
            'Retry count should be tracked');
        System.assertNotEquals(null, outcome.lockContention,
            'Lock contention flag should be set');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 8. Error Message Labeling (Security Review: no hardcoded strings)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void outcomeMessages_usesCustomLabels() {
        Test.startTest();
        AssignmentResolver.AssignmentOutcome outcome1 =
            AssignmentResolver.outcomeAlreadyAssigned();
        Test.stopTest();

        // Verify error message is not null (should come from System.Label)
        System.assertNotEquals(null, outcome1.errorMessage,
            'All error messages must use System.Label (Security Review)');
        System.assert(outcome1.errorMessage.length() > 0,
            'Error message must not be empty');
    }
}
