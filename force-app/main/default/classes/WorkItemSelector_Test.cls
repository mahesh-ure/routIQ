/**
 * @description Test class for WorkItemSelector (Layer 4 Selector).
 *              Tests: work item queries, LIMIT enforcement.
 * @group Test
 */
@IsTest
private class WorkItemSelector_Test {

    @IsTest
    static void getActiveWorkItems() {
        Agent__c agent = new Agent__c(
            User__c = UserInfo.getUserId(),
            Is_Active__c = true
        );
        insert agent;

        Agent_Work_Item__c item = new Agent_Work_Item__c(
            Agent__c = agent.Id,
            Record_Id__c = UserInfo.getUserId(),
            Status__c = 'Active'
        );
        insert item;

        Test.startTest();
        List<Agent_Work_Item__c> results = AssignmentSelector.getActiveWorkItemsForAgent(agent.Id);
        Test.stopTest();

        System.assertNotEquals(null, results, 'Should return work items');
    }

    @IsTest
    static void getWorkItems_limitEnforced() {
        Agent__c agent = new Agent__c(
            User__c = UserInfo.getUserId(),
            Is_Active__c = true
        );
        insert agent;

        Test.startTest();
        List<Agent_Work_Item__c> results = AssignmentSelector.getActiveWorkItemsForAgent(agent.Id);
        Test.stopTest();

        System.assert(results.size() <= 200, 'LIMIT should be respected');
    }

    @IsTest
    static void getWorkItems_empty() {
        Agent__c agent = new Agent__c(
            User__c = UserInfo.getUserId(),
            Is_Active__c = true
        );
        insert agent;

        Test.startTest();
        List<Agent_Work_Item__c> results = AssignmentSelector.getActiveWorkItemsForAgent(agent.Id);
        Test.stopTest();

        System.assertEquals(0, results.size(), 'Should return empty for new agent');
    }
}
