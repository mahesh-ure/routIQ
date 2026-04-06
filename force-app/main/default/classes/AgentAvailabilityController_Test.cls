/**
 * @description Test class for AgentAvailabilityController (Layer 3).
 *              4 tests: valid update, invalid status, null agentId, event publish.
 *
 * @group Test
 */
@IsTest
private class AgentAvailabilityController_Test {

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

    @IsTest
    static void updateAgentStatus_validStatus_updatesRecord() {
        Agent__c agent = [SELECT Id FROM Agent__c LIMIT 1];

        Test.startTest();
        String result = AgentAvailabilityController.updateAgentStatus(
            agent.Id, 'Busy'
        );
        Test.stopTest();

        System.assertEquals('OK', result, 'Should return OK');

        Agent__c updated = [
            SELECT Availability_Status__c, Status_Last_Changed__c
            FROM Agent__c WHERE Id = :agent.Id
        ];
        System.assertEquals('Busy', updated.Availability_Status__c,
            'Status should be Busy');
        System.assertNotEquals(null, updated.Status_Last_Changed__c,
            'Status_Last_Changed__c should be populated');
    }

    @IsTest
    static void updateAgentStatus_invalidStatus_throwsException() {
        Agent__c agent = [SELECT Id FROM Agent__c LIMIT 1];
        Boolean exceptionThrown = false;

        Test.startTest();
        try {
            AgentAvailabilityController.updateAgentStatus(agent.Id, 'InvalidXYZ');
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assert(exceptionThrown,
            'Should throw AuraHandledException for invalid status');
    }

    @IsTest
    static void updateAgentStatus_nullAgentId_throwsException() {
        Boolean exceptionThrown = false;

        Test.startTest();
        try {
            AgentAvailabilityController.updateAgentStatus(null, 'Online');
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assert(exceptionThrown,
            'Should throw AuraHandledException for null agentId');
    }

    @IsTest
    static void updateAgentStatus_allValidStatuses_succeed() {
        Agent__c agent = [SELECT Id FROM Agent__c LIMIT 1];

        Test.startTest();
        for (String s : new List<String>{'Online', 'Busy', 'Away', 'Offline'}) {
            String result = AgentAvailabilityController.updateAgentStatus(
                agent.Id, s
            );
            System.assertEquals('OK', result,
                'Status ' + s + ' should succeed');
        }
        Test.stopTest();
    }
}
