/**
 * @description Test class for WorkItemSelector and WorkItemService.
 *              Tests the full work item lifecycle:
 *              - createWorkItem:     creates Agent_Work_Item__c + syncs load
 *              - completeWorkItem:   removes item on record closure + syncs load
 *              - completeWorkItems:  bulk completion via @InvocableMethod
 *              - deferWorkItem:      removes item on defer + syncs load
 *              - escalateWorkItem:   removes item on escalation + syncs load
 *              - syncAgentLoad:      load = COUNT of active items (no drift)
 *
 *              Validates the BUG FIX: Current_Load__c now updates correctly
 *              because it is derived from actual Agent_Work_Item__c records.
 *
 * @group Test
 */
@IsTest
private class WorkItemService_Test {

    private static final String CONFIG_DEV_NAME = 'Test_Case_Routing';

    // =========================================================================
    // TEST SETUP
    // =========================================================================

    @TestSetup
    static void setup() {
        Agent__c agent = new Agent__c(
            User__c = UserInfo.getUserId(),
            Is_Active__c = true,
            Max_Capacity__c = 10,
            Current_Load__c = 0,
            Availability_Status__c = 'Online'
        );
        insert agent;
    }

    // =========================================================================
    // HELPERS
    // =========================================================================

    private static Agent__c getAgent() {
        return [
            SELECT Id, Current_Load__c, Max_Capacity__c, User__c
            FROM   Agent__c
            WHERE  User__c = :UserInfo.getUserId()
            LIMIT  1
        ];
    }

    private static Case createTestCase(String subject) {
        Case c = new Case(Subject = subject, Status = 'New');
        insert c;
        return c;
    }

    // =========================================================================
    // 1. createWorkItem TESTS
    // =========================================================================

    @IsTest
    static void createWorkItem_validInputs_createsItemAndSyncsLoad() {
        Agent__c agent = getAgent();
        Case testCase = createTestCase('Test Assignment');

        Test.startTest();
        WorkItemService.createWorkItem(
            agent.Id,
            testCase.Id,
            'Case',
            CONFIG_DEV_NAME
        );
        Test.stopTest();

        // Verify work item created
        List<Agent_Work_Item__c> items = [
            SELECT Id, Record_Id__c, Object_API_Name__c,
                   Config_Developer_Name__c, Status__c, Agent__c
            FROM   Agent_Work_Item__c
            WHERE  Agent__c = :agent.Id
        ];
        System.assertEquals(1, items.size(), 'Should create 1 work item');
        System.assertEquals(String.valueOf(testCase.Id), items[0].Record_Id__c,
            'Record Id should match');
        System.assertEquals('Case', items[0].Object_API_Name__c,
            'Object API name should match');
        System.assertEquals('Active', items[0].Status__c,
            'Status should be Active');

        // Verify agent load synced (BUG FIX verification)
        Agent__c updatedAgent = getAgent();
        System.assertEquals(1, updatedAgent.Current_Load__c,
            'Agent Current_Load__c should be 1 after assignment');
    }

    @IsTest
    static void createWorkItem_nullInputs_doesNothing() {
        Test.startTest();
        WorkItemService.createWorkItem(null, null, 'Case', CONFIG_DEV_NAME);
        Test.stopTest();

        List<Agent_Work_Item__c> items = [
            SELECT Id FROM Agent_Work_Item__c
        ];
        System.assertEquals(0, items.size(), 'Should not create items for null inputs');
    }

    @IsTest
    static void createWorkItem_multipleItems_incrementsLoadAccurately() {
        Agent__c agent = getAgent();

        Test.startTest();
        // Create 3 work items
        for (Integer i = 0; i < 3; i++) {
            Case c = createTestCase('Multi Test ' + i);
            WorkItemService.createWorkItem(
                agent.Id, c.Id, 'Case', CONFIG_DEV_NAME
            );
        }
        Test.stopTest();

        Agent__c updatedAgent = getAgent();
        System.assertEquals(3, updatedAgent.Current_Load__c,
            'Agent load should be 3 after 3 assignments');
    }

    // =========================================================================
    // 2. completeWorkItem TESTS (InvocableMethod)
    // =========================================================================

    @IsTest
    static void completeWorkItem_invocable_removesItemAndSyncsLoad() {
        Agent__c agent = getAgent();
        Case testCase = createTestCase('Complete Test');

        // Create a work item
        Agent_Work_Item__c item = new Agent_Work_Item__c(
            Agent__c = agent.Id,
            Record_Id__c = String.valueOf(testCase.Id),
            Object_API_Name__c = 'Case',
            Config_Developer_Name__c = CONFIG_DEV_NAME,
            Assigned_At__c = System.now(),
            Status__c = 'Active'
        );
        insert item;

        // Manually set load to 1
        agent.Current_Load__c = 1;
        update agent;

        // Build invocable input
        WorkItemService.CompleteWorkItemInput input =
            new WorkItemService.CompleteWorkItemInput();
        input.recordId = String.valueOf(testCase.Id);

        Test.startTest();
        WorkItemService.completeWorkItem(
            new List<WorkItemService.CompleteWorkItemInput>{ input }
        );
        Test.stopTest();

        // Verify work item deleted
        List<Agent_Work_Item__c> remaining = [
            SELECT Id FROM Agent_Work_Item__c WHERE Agent__c = :agent.Id
        ];
        System.assertEquals(0, remaining.size(),
            'Work item should be deleted on completion');

        // Verify load synced to 0
        Agent__c updatedAgent = getAgent();
        System.assertEquals(0, updatedAgent.Current_Load__c,
            'Agent load should be 0 after completion');
    }

    @IsTest
    static void completeWorkItems_bulk_handlesMultipleRecords() {
        Agent__c agent = getAgent();

        // Create 3 cases with work items
        List<Agent_Work_Item__c> items = new List<Agent_Work_Item__c>();
        Set<String> recordIds = new Set<String>();
        for (Integer i = 0; i < 3; i++) {
            Case c = createTestCase('Bulk Complete ' + i);
            String caseId = String.valueOf(c.Id);
            recordIds.add(caseId);
            items.add(new Agent_Work_Item__c(
                Agent__c = agent.Id,
                Record_Id__c = caseId,
                Object_API_Name__c = 'Case',
                Config_Developer_Name__c = CONFIG_DEV_NAME,
                Assigned_At__c = System.now(),
                Status__c = 'Active'
            ));
        }
        insert items;

        agent.Current_Load__c = 3;
        update agent;

        Test.startTest();
        WorkItemService.completeWorkItems(recordIds);
        Test.stopTest();

        List<Agent_Work_Item__c> remaining = [
            SELECT Id FROM Agent_Work_Item__c WHERE Agent__c = :agent.Id
        ];
        System.assertEquals(0, remaining.size(),
            'All work items should be deleted');

        Agent__c updatedAgent = getAgent();
        System.assertEquals(0, updatedAgent.Current_Load__c,
            'Agent load should be 0 after bulk completion');
    }

    // =========================================================================
    // 3. deferWorkItem TESTS
    // =========================================================================

    @IsTest
    static void deferWorkItem_validItem_removesAndSyncsLoad() {
        Agent__c agent = getAgent();
        Case testCase = createTestCase('Defer Test');

        // Create work item
        Agent_Work_Item__c item = new Agent_Work_Item__c(
            Agent__c = agent.Id,
            Record_Id__c = String.valueOf(testCase.Id),
            Object_API_Name__c = 'Case',
            Config_Developer_Name__c = CONFIG_DEV_NAME,
            Assigned_At__c = System.now(),
            Status__c = 'Active'
        );
        insert item;

        agent.Current_Load__c = 1;
        update agent;

        Test.startTest();
        WorkItemService.deferWorkItem(String.valueOf(testCase.Id));
        Test.stopTest();

        List<Agent_Work_Item__c> remaining = [
            SELECT Id FROM Agent_Work_Item__c WHERE Agent__c = :agent.Id
        ];
        System.assertEquals(0, remaining.size(),
            'Work item should be removed on defer');

        Agent__c updatedAgent = getAgent();
        System.assertEquals(0, updatedAgent.Current_Load__c,
            'Agent load should be 0 after defer');
    }

    @IsTest
    static void deferWorkItem_noItem_doesNothing() {
        Test.startTest();
        WorkItemService.deferWorkItem('500000000000999');
        Test.stopTest();

        // Should not throw — silently skips
        Agent__c agent = getAgent();
        System.assertEquals(0, agent.Current_Load__c,
            'Agent load should remain 0');
    }

    // =========================================================================
    // 4. escalateWorkItem TESTS
    // =========================================================================

    @IsTest
    static void escalateWorkItem_removesAndSyncsLoad() {
        Agent__c agent = getAgent();
        Case testCase = createTestCase('Escalate Test');

        Agent_Work_Item__c item = new Agent_Work_Item__c(
            Agent__c = agent.Id,
            Record_Id__c = String.valueOf(testCase.Id),
            Object_API_Name__c = 'Case',
            Config_Developer_Name__c = CONFIG_DEV_NAME,
            Assigned_At__c = System.now(),
            Status__c = 'Active'
        );
        insert item;

        agent.Current_Load__c = 1;
        update agent;

        Test.startTest();
        WorkItemService.escalateWorkItem(item);
        Test.stopTest();

        List<Agent_Work_Item__c> remaining = [
            SELECT Id FROM Agent_Work_Item__c WHERE Agent__c = :agent.Id
        ];
        System.assertEquals(0, remaining.size(),
            'Work item should be removed on escalation');

        Agent__c updatedAgent = getAgent();
        System.assertEquals(0, updatedAgent.Current_Load__c,
            'Agent load should be 0 after escalation');
    }

    // =========================================================================
    // 5. SELECTOR TESTS
    // =========================================================================

    @IsTest
    static void selector_getActiveByRecordId_returnsCorrectItem() {
        Agent__c agent = getAgent();
        Case testCase = createTestCase('Selector Test');
        String caseId = String.valueOf(testCase.Id);

        Agent_Work_Item__c item = new Agent_Work_Item__c(
            Agent__c = agent.Id,
            Record_Id__c = caseId,
            Object_API_Name__c = 'Case',
            Config_Developer_Name__c = CONFIG_DEV_NAME,
            Assigned_At__c = System.now(),
            Status__c = 'Active'
        );
        insert item;

        Test.startTest();
        Agent_Work_Item__c found =
            WorkItemSelector.getActiveByRecordId(caseId);
        Test.stopTest();

        System.assertNotEquals(null, found, 'Should find the active work item');
        System.assertEquals(caseId, found.Record_Id__c,
            'Record Id should match');
    }

    @IsTest
    static void selector_countActiveByAgentId_returnsCorrectCount() {
        Agent__c agent = getAgent();

        // Create 2 active items
        List<Agent_Work_Item__c> items = new List<Agent_Work_Item__c>();
        for (Integer i = 0; i < 2; i++) {
            Case c = createTestCase('Count Test ' + i);
            items.add(new Agent_Work_Item__c(
                Agent__c = agent.Id,
                Record_Id__c = String.valueOf(c.Id),
                Object_API_Name__c = 'Case',
                Config_Developer_Name__c = CONFIG_DEV_NAME,
                Assigned_At__c = System.now(),
                Status__c = 'Active'
            ));
        }
        insert items;

        Test.startTest();
        Integer count = WorkItemSelector.countActiveByAgentId(agent.Id);
        Test.stopTest();

        System.assertEquals(2, count, 'Count should be 2');
    }

    @IsTest
    static void selector_getAllActive_returnsAllActive() {
        Agent__c agent = getAgent();
        Case testCase = createTestCase('All Active Test');

        Agent_Work_Item__c item = new Agent_Work_Item__c(
            Agent__c = agent.Id,
            Record_Id__c = String.valueOf(testCase.Id),
            Object_API_Name__c = 'Case',
            Config_Developer_Name__c = CONFIG_DEV_NAME,
            Assigned_At__c = System.now(),
            Status__c = 'Active'
        );
        insert item;

        Test.startTest();
        List<Agent_Work_Item__c> allActive = WorkItemSelector.getAllActive();
        Test.stopTest();

        System.assert(!allActive.isEmpty(), 'Should return at least 1 active item');
    }

    // =========================================================================
    // 6. LOAD SYNC ACCURACY (BUG FIX REGRESSION TEST)
    // =========================================================================

    @IsTest
    static void loadSync_afterMixedOperations_remainsAccurate() {
        Agent__c agent = getAgent();

        // Create 3 work items
        List<Id> caseIds = new List<Id>();
        for (Integer i = 0; i < 3; i++) {
            Case c = createTestCase('Sync Test ' + i);
            caseIds.add(c.Id);
            WorkItemService.createWorkItem(
                agent.Id, c.Id, 'Case', CONFIG_DEV_NAME
            );
        }

        // Verify load is 3
        Agent__c a1 = getAgent();
        System.assertEquals(3, a1.Current_Load__c,
            'Load should be 3 after 3 creates');

        Test.startTest();

        // Complete 1
        WorkItemService.completeWorkItems(
            new Set<String>{ String.valueOf(caseIds[0]) }
        );

        // Defer 1
        WorkItemService.deferWorkItem(String.valueOf(caseIds[1]));

        Test.stopTest();

        // Load should be 1 (3 - 1 completed - 1 deferred)
        Agent__c a2 = getAgent();
        System.assertEquals(1, a2.Current_Load__c,
            'Load should be 1 after 1 complete + 1 defer');
    }
}
