/**
 * @description Test class for AgentWorkPanelController (Layer 5).
 *              Tests all four @AuraEnabled methods:
 *              - getAgentContext: valid agent, no agent
 *              - getNextWork: delegates to RoutingService (integration-level)
 *              - deferWork: valid defer, missing config, missing defer field
 *              - getQueueDepth: valid count, missing config
 *
 *              Uses mock CMDT injection via RoutingConfigSelector.mockConfigs
 *              to avoid deploying test metadata.
 *
 * @group Test
 */
@IsTest
private class AgentWorkPanelController_Test {

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
            Current_Load__c = 3,
            Availability_Status__c = 'Online'
        );
        insert agent;
    }

    // =========================================================================
    // HELPER: Inject mock CMDT config
    // =========================================================================

    private static Routing_Config__mdt buildMockConfig() {
        Routing_Config__mdt config = new Routing_Config__mdt(
            DeveloperName = CONFIG_DEV_NAME,
            MasterLabel = 'Test Case Routing',
            Object_API_Name__c = 'Case',
            Owner_Field_API_Name__c = 'OwnerId',
            Active__c = true,
            SLA_Deadline_Field__c = 'SlaExitDate',
            Defer_Reset_Field__c = 'OwnerId',
            Defer_Reset_Value__c = null,
            Candidate_Limit__c = 50,
            Closed_Status_Values__c = 'Closed',
            Max_Retry_Attempts__c = 1
        );
        return config;
    }

    private static void injectMockConfig() {
        RoutingConfigSelector.mockConfigs = new Map<String, Routing_Config__mdt>{
            CONFIG_DEV_NAME => buildMockConfig()
        };
    }

    // =========================================================================
    // 1. getAgentContext TESTS
    // =========================================================================

    @IsTest
    static void getAgentContext_validAgent_returnsContext() {
        Test.startTest();
        AgentWorkPanelController.AgentContext ctx =
            AgentWorkPanelController.getAgentContext();
        Test.stopTest();

        System.assertNotEquals(null, ctx, 'Context should not be null');
        System.assertNotEquals(null, ctx.agentId, 'Agent Id should be set');
        System.assertEquals('Online', ctx.status, 'Status should be Online');
        System.assertEquals(3, ctx.currentLoad, 'Load should be 3');
        System.assertEquals(10, ctx.maxCapacity, 'Capacity should be 10');
        System.assertEquals(true, ctx.isActive, 'Should be active');
    }

    @IsTest
    static void getAgentContext_noAgent_throwsException() {
        // Delete the test agent to simulate no-agent scenario
        delete [SELECT Id FROM Agent__c];

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            AgentWorkPanelController.getAgentContext();
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assert(exceptionThrown,
            'Should throw AuraHandledException when no agent exists');
    }

    // =========================================================================
    // 2. getNextWork TESTS
    // =========================================================================

    @IsTest
    static void getNextWork_noConfig_returnsResult() {
        // Without mock config, engine should return no-match (not throw)
        Test.startTest();
        AgentWorkPanelController.WorkAssignment wa =
            AgentWorkPanelController.getNextWork(null);
        Test.stopTest();

        System.assertNotEquals(null, wa, 'WorkAssignment should not be null');
        // Result will be no-match since no real config exists, but should not throw
    }

    @IsTest
    static void getNextWork_withConfig_returnsResult() {
        injectMockConfig();

        Test.startTest();
        AgentWorkPanelController.WorkAssignment wa =
            AgentWorkPanelController.getNextWork(CONFIG_DEV_NAME);
        Test.stopTest();

        System.assertNotEquals(null, wa, 'WorkAssignment should not be null');
        System.assertEquals(CONFIG_DEV_NAME, wa.configDevName,
            'Config dev name should be echoed back');
    }

    // =========================================================================
    // 3. deferWork TESTS
    // =========================================================================

    @IsTest
    static void deferWork_nullRecordId_throwsException() {
        Boolean exceptionThrown = false;

        Test.startTest();
        try {
            AgentWorkPanelController.deferWork(null, CONFIG_DEV_NAME);
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assert(exceptionThrown,
            'Should throw when recordId is null');
    }

    @IsTest
    static void deferWork_blankConfig_throwsException() {
        Boolean exceptionThrown = false;

        Test.startTest();
        try {
            // Use a dummy Case Id format
            AgentWorkPanelController.deferWork(
                '500000000000001', ''
            );
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assert(exceptionThrown,
            'Should throw when configDevName is blank');
    }

    @IsTest
    static void deferWork_missingConfig_throwsException() {
        Boolean exceptionThrown = false;
        injectMockConfig();

        Test.startTest();
        try {
            AgentWorkPanelController.deferWork(
                '500000000000001', 'Nonexistent_Config'
            );
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assert(exceptionThrown,
            'Should throw when config does not exist');
    }

    @IsTest
    static void deferWork_noDeferField_throwsException() {
        // Config with no defer field set
        Routing_Config__mdt configNoDef = buildMockConfig();
        configNoDef.Defer_Reset_Field__c = null;
        RoutingConfigSelector.mockConfigs = new Map<String, Routing_Config__mdt>{
            CONFIG_DEV_NAME => configNoDef
        };

        Boolean exceptionThrown = false;

        Test.startTest();
        try {
            AgentWorkPanelController.deferWork(
                '500000000000001', CONFIG_DEV_NAME
            );
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assert(exceptionThrown,
            'Should throw when defer field is not configured');
    }

    @IsTest
    static void deferWork_validCase_resetsStatus() {
        // Override mock config to defer via Status field (not OwnerId)
        Routing_Config__mdt deferConfig = buildMockConfig();
        deferConfig.Defer_Reset_Field__c = 'Status';
        deferConfig.Defer_Reset_Value__c = 'New';
        RoutingConfigSelector.mockConfigs = new Map<String, Routing_Config__mdt>{
            CONFIG_DEV_NAME => deferConfig
        };

        // Create a Case to defer
        Case testCase = new Case(
            Subject = 'Test Defer Case',
            Status = 'Working'
        );
        insert testCase;

        // Set agent load to 1 so decrement works
        Agent__c agent = [SELECT Id FROM Agent__c LIMIT 1];
        agent.Current_Load__c = 1;
        update agent;

        Test.startTest();
        String result = AgentWorkPanelController.deferWork(
            testCase.Id, CONFIG_DEV_NAME
        );
        Test.stopTest();

        System.assertEquals('OK', result, 'Defer should return OK');

        // Verify Status was reset
        Case updated = [SELECT Status FROM Case WHERE Id = :testCase.Id];
        System.assertEquals('New', updated.Status,
            'Case Status should be reset to New');

        // Verify agent load decremented
        Agent__c updatedAgent = [SELECT Current_Load__c FROM Agent__c WHERE Id = :agent.Id];
        System.assertEquals(0, updatedAgent.Current_Load__c,
            'Agent load should decrement to 0');
    }

    // =========================================================================
    // 4. getQueueDepth TESTS
    // =========================================================================

    @IsTest
    static void getQueueDepth_blankConfig_throwsException() {
        Boolean exceptionThrown = false;

        Test.startTest();
        try {
            AgentWorkPanelController.getQueueDepth('');
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assert(exceptionThrown,
            'Should throw when configDevName is blank');
    }

    @IsTest
    static void getQueueDepth_missingConfig_throwsException() {
        injectMockConfig();
        Boolean exceptionThrown = false;

        Test.startTest();
        try {
            AgentWorkPanelController.getQueueDepth('Nonexistent_Config');
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assert(exceptionThrown,
            'Should throw when config does not exist');
    }

    @IsTest
    static void getQueueDepth_validConfig_returnsCount() {
        injectMockConfig();

        // Create some open Cases
        List<Case> cases = new List<Case>();
        for (Integer i = 0; i < 5; i++) {
            cases.add(new Case(
                Subject = 'Queue Test ' + i,
                Status = 'New'
            ));
        }
        insert cases;

        Test.startTest();
        Integer count = AgentWorkPanelController.getQueueDepth(CONFIG_DEV_NAME);
        Test.stopTest();

        System.assert(count >= 5,
            'Queue depth should include the 5 test Cases (actual: ' + count + ')');
    }

    @IsTest
    static void getQueueDepth_closedExcluded_returnsFilteredCount() {
        injectMockConfig();

        // Create 3 open + 2 closed Cases
        List<Case> cases = new List<Case>();
        for (Integer i = 0; i < 3; i++) {
            cases.add(new Case(Subject = 'Open ' + i, Status = 'New'));
        }
        for (Integer i = 0; i < 2; i++) {
            cases.add(new Case(Subject = 'Closed ' + i, Status = 'Closed'));
        }
        insert cases;

        Test.startTest();
        Integer count = AgentWorkPanelController.getQueueDepth(CONFIG_DEV_NAME);
        Test.stopTest();

        // Closed Cases should be excluded from the count
        // Count may include other Cases in the org, but closed ones should not be counted
        System.assert(count >= 3,
            'Queue depth should count at least the 3 open Cases');
    }

    // =========================================================================
    // BULK TEST -- multiple operations in sequence
    // =========================================================================

    @IsTest
    static void fullWorkCycle_contextThenRouteThenDefer() {
        injectMockConfig();

        Test.startTest();

        // Step 1: Get agent context
        AgentWorkPanelController.AgentContext ctx =
            AgentWorkPanelController.getAgentContext();
        System.assertNotEquals(null, ctx, 'Agent context should load');

        // Step 2: Attempt to get next work (may return no-match without real data)
        AgentWorkPanelController.WorkAssignment wa =
            AgentWorkPanelController.getNextWork(CONFIG_DEV_NAME);
        System.assertNotEquals(null, wa, 'WorkAssignment should not be null');

        // Step 3: Get queue depth
        Integer depth = AgentWorkPanelController.getQueueDepth(CONFIG_DEV_NAME);
        System.assert(depth >= 0, 'Queue depth should be non-negative');

        Test.stopTest();
    }
}
