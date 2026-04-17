/**
 * @description Test class for WorkItemService (Layer 3 Service).
 *              Tests: work item lifecycle, agent load sync.
 * @group Test
 */
@IsTest
private class WorkItemService_Test {

    @TestSetup
    static void setup() {
        Agent__c agent = new Agent__c(
            User__c = UserInfo.getUserId(),
            Is_Active__c = true,
            Current_Load__c = 0,
            Max_Capacity__c = 50
        );
        insert agent;
    }

    @IsTest
    static void createWorkItem_success() {
        Agent__c agent = [SELECT Id FROM Agent__c LIMIT 1];
        Case testCase = new Case(Subject = 'Test', Status = 'New');
        insert testCase;

        Test.startTest();
        WorkItemService.createWorkItem(
            agent.Id, testCase.Id, 'Case', 'TestConfig'
        );
        Test.stopTest();

        List<Agent_Work_Item__c> items = [
            SELECT Id, Status__c FROM Agent_Work_Item__c
            WHERE Agent__c = :agent.Id
        ];
        System.assertEquals(1, items.size(), 'Work item created');
        System.assertEquals('Active', items[0].Status__c, 'Status is Active');
    }

    @IsTest
    static void createWorkItem_nullAgent() {
        Case testCase = new Case(Subject = 'Test', Status = 'New');
        insert testCase;

        Test.startTest();
        WorkItemService.createWorkItem(
            null, testCase.Id, 'Case', 'TestConfig'
        );
        Test.stopTest();

        List<Agent_Work_Item__c> items = [SELECT Id FROM Agent_Work_Item__c];
        System.assertEquals(0, items.size(), 'Should skip null agent');
    }

    @IsTest
    static void createWorkItem_nullRecord() {
        Agent__c agent = [SELECT Id FROM Agent__c LIMIT 1];

        Test.startTest();
        WorkItemService.createWorkItem(agent.Id, null, 'Case', 'TestConfig');
        Test.stopTest();

        List<Agent_Work_Item__c> items = [SELECT Id FROM Agent_Work_Item__c];
        System.assertEquals(0, items.size(), 'Should skip null record');
    }

    @IsTest
    static void bulkCreateWorkItems() {
        Agent__c agent = [SELECT Id FROM Agent__c LIMIT 1];

        Test.startTest();
        for (Integer i = 0; i < 5; i++) {
            Case c = new Case(Subject = 'Case ' + i, Status = 'New');
            insert c;
            WorkItemService.createWorkItem(
                agent.Id, c.Id, 'Case', 'Config' + i
            );
        }
        Test.stopTest();

        List<Agent_Work_Item__c> items = [
            SELECT Id FROM Agent_Work_Item__c WHERE Agent__c = :agent.Id
        ];
        System.assertEquals(5, items.size(), 'Should create 5 items');
    }
}
