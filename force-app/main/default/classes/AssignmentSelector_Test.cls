/**
 * @description Test class for AssignmentSelector.getActiveWorkItemsForAgent —
 *              the new accessor that powers the Agent Work Panel's pre-existing
 *              assignment hydration.
 *
 *              Existing AssignmentSelector methods (lockRecord, queryOwnedRecords,
 *              queryRecordName) are exercised indirectly via RoutingEngine /
 *              AssignmentResolver tests. This class covers the active-work-item
 *              accessor specifically.
 *
 * @group Test
 */
@IsTest
private class AssignmentSelector_Test {

    @TestSetup
    static void setup() {
        insert new Agent__c(
            User__c                = UserInfo.getUserId(),
            Is_Active__c           = true,
            Max_Capacity__c        = 10,
            Current_Load__c        = 0,
            Availability_Status__c = 'Online'
        );
    }

    @IsTest
    static void getActiveWorkItemsForAgent_nullAgentId_returnsEmpty() {
        Test.startTest();
        List<Agent_Work_Item__c> items =
            AssignmentSelector.getActiveWorkItemsForAgent(null);
        Test.stopTest();

        System.assertNotEquals(null, items, 'Must never return null');
        System.assertEquals(0, items.size(), 'Null agentId short-circuits to empty list');
    }

    @IsTest
    static void getActiveWorkItemsForAgent_noRows_returnsEmpty() {
        Agent__c agent = [SELECT Id FROM Agent__c LIMIT 1];

        Test.startTest();
        List<Agent_Work_Item__c> items =
            AssignmentSelector.getActiveWorkItemsForAgent(agent.Id);
        Test.stopTest();

        System.assertEquals(0, items.size(),
            'Agent with no work items should return an empty list');
    }

    @IsTest
    static void getActiveWorkItemsForAgent_returnsOnlyActiveStatus() {
        Agent__c agent = [SELECT Id FROM Agent__c LIMIT 1];

        Case c1 = new Case(Subject = 'Active', Status = 'New');
        Case c2 = new Case(Subject = 'Completed', Status = 'New');
        Case c3 = new Case(Subject = 'Deferred', Status = 'New');
        insert new List<Case>{ c1, c2, c3 };

        insert new List<Agent_Work_Item__c>{
            new Agent_Work_Item__c(
                Agent__c = agent.Id, Record_Id__c = String.valueOf(c1.Id),
                Object_API_Name__c = 'Case', Config_Developer_Name__c = 'X',
                Assigned_At__c = System.now(), Status__c = 'Active'
            ),
            new Agent_Work_Item__c(
                Agent__c = agent.Id, Record_Id__c = String.valueOf(c2.Id),
                Object_API_Name__c = 'Case', Config_Developer_Name__c = 'X',
                Assigned_At__c = System.now(), Status__c = 'Completed'
            ),
            new Agent_Work_Item__c(
                Agent__c = agent.Id, Record_Id__c = String.valueOf(c3.Id),
                Object_API_Name__c = 'Case', Config_Developer_Name__c = 'X',
                Assigned_At__c = System.now(), Status__c = 'Deferred'
            )
        };

        Test.startTest();
        List<Agent_Work_Item__c> items =
            AssignmentSelector.getActiveWorkItemsForAgent(agent.Id);
        Test.stopTest();

        System.assertEquals(1, items.size(),
            'Only the Active-status row should be returned');
        System.assertEquals('Active', items[0].Status__c,
            'Returned row must be the Active one');
    }

    @IsTest
    static void getActiveWorkItemsForAgent_orderedByAssignedAtAsc() {
        Agent__c agent = [SELECT Id FROM Agent__c LIMIT 1];

        Case c1 = new Case(Subject = 'Old', Status = 'New');
        Case c2 = new Case(Subject = 'New', Status = 'New');
        insert new List<Case>{ c1, c2 };

        Datetime older = System.now().addMinutes(-60);
        Datetime newer = System.now();

        insert new List<Agent_Work_Item__c>{
            new Agent_Work_Item__c(
                Agent__c = agent.Id, Record_Id__c = String.valueOf(c2.Id),
                Object_API_Name__c = 'Case', Config_Developer_Name__c = 'X',
                Assigned_At__c = newer, Status__c = 'Active'
            ),
            new Agent_Work_Item__c(
                Agent__c = agent.Id, Record_Id__c = String.valueOf(c1.Id),
                Object_API_Name__c = 'Case', Config_Developer_Name__c = 'X',
                Assigned_At__c = older, Status__c = 'Active'
            )
        };

        Test.startTest();
        List<Agent_Work_Item__c> items =
            AssignmentSelector.getActiveWorkItemsForAgent(agent.Id);
        Test.stopTest();

        System.assertEquals(2, items.size(), 'Both active items returned');
        System.assert(items[0].Assigned_At__c <= items[1].Assigned_At__c,
            'Oldest assignment must come first (urgency ordering)');
    }

    @IsTest
    static void getActiveWorkItemsForAgent_mockOverrideHonoured() {
        // Prove @TestVisible mock injection works for test isolation in
        // downstream consumers (same pattern used elsewhere in the codebase).
        Agent_Work_Item__c mock = new Agent_Work_Item__c(
            Record_Id__c             = '500000000000001AAA',
            Object_API_Name__c       = 'Case',
            Config_Developer_Name__c = 'Mocked',
            Assigned_At__c           = System.now(),
            Status__c                = 'Active'
        );
        AssignmentSelector.mockActiveWorkItems =
            new List<Agent_Work_Item__c>{ mock };

        Test.startTest();
        List<Agent_Work_Item__c> items =
            AssignmentSelector.getActiveWorkItemsForAgent('a00000000000001AAA');
        Test.stopTest();

        System.assertEquals(1, items.size(), 'Mock must be returned verbatim');
        System.assertEquals('Mocked', items[0].Config_Developer_Name__c,
            'Mock override short-circuits the real SOQL');
    }
}
