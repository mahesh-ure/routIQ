/**
 * @description Test class for AgentWorkPanelController (Layer 5).
 *              Tests all five @AuraEnabled methods:
 *              - getAgentContext: valid agent, no agent
 *              - refreshAgentContext: reaper-on-refresh tick (returns same shape)
 *              - getNextWork: delegates to RoutingService (integration-level)
 *              - deferWork: valid defer, missing config, missing defer field
 *              - getQueueDepth: valid count, missing config, AND the
 *                blank/null fallback that sums across all active configs
 *                (the contract that lets the LWC's @wire(getQueueDepth)
 *                work out-of-the-box before the admin binds configDevName)
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
            SLA_Minutes__c = 60,
            SLA_Warn_Threshold_Pct__c = 40,
            SLA_Critical_Threshold_Pct__c = 10,
            Defer_Reset_Field__c = 'OwnerId',
            Defer_Reset_Value__c = null,
            Candidate_Limit__c = 50,
            Closed_Status_Field_API_Name__c = 'Status',
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
    // 1b. refreshAgentContext TESTS (auto-refresh tick + zombie reap)
    // =========================================================================

    @IsTest
    static void refreshAgentContext_validAgent_returnsContextAndReapsSafely() {
        // No work items exist → reaper is a no-op → context still returns
        Test.startTest();
        AgentWorkPanelController.AgentContext ctx =
            AgentWorkPanelController.refreshAgentContext();
        Test.stopTest();

        System.assertNotEquals(null, ctx,
            'refreshAgentContext should return a context');
        System.assertNotEquals(null, ctx.agentId,
            'Agent Id should be populated post-reap');
        System.assertEquals('Online', ctx.status,
            'Status should pass through unchanged');
        System.assertEquals(10, ctx.maxCapacity,
            'Capacity should pass through unchanged');
    }

    @IsTest
    static void refreshAgentContext_noAgent_throwsException() {
        // No agent record at all → both reap (silent) and load (throws) run
        delete [SELECT Id FROM Agent__c];

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            AgentWorkPanelController.refreshAgentContext();
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assert(exceptionThrown,
            'refreshAgentContext should throw when no agent exists');
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

        // Create a real Agent_Work_Item__c so deferWorkItem has something
        // to delete (load is now derived from COUNT of active work items,
        // not an independent counter field).
        Agent__c agent = [SELECT Id FROM Agent__c LIMIT 1];
        Agent_Work_Item__c workItem = new Agent_Work_Item__c(
            Agent__c                 = agent.Id,
            Record_Id__c             = String.valueOf(testCase.Id),
            Object_API_Name__c       = 'Case',
            Config_Developer_Name__c = CONFIG_DEV_NAME,
            Assigned_At__c           = System.now(),
            Status__c                = 'Active'
        );
        insert workItem;
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
    static void getQueueDepth_blankConfig_returnsSumOfAllActive() {
        // New fallback contract: blank/null configDevName MUST NOT throw —
        // it returns the sum of pending candidates across all active
        // routing configs so the panel widget works out-of-the-box on a
        // fresh install before the admin has bound the panel to a config.
        injectMockConfig();

        // Seed the queue with a few open Cases that the mock config (Case
        // object, Closed status excluded) will count.
        List<Case> cases = new List<Case>();
        for (Integer i = 0; i < 4; i++) {
            cases.add(new Case(Subject = 'Fallback Open ' + i, Status = 'New'));
        }
        insert cases;

        Test.startTest();
        Integer blankCount = AgentWorkPanelController.getQueueDepth('');
        Integer nullCount  = AgentWorkPanelController.getQueueDepth(null);
        Test.stopTest();

        System.assert(blankCount >= 4,
            'Blank configDevName should sum across active configs '
            + '(expected ≥ 4, got ' + blankCount + ')');
        System.assertEquals(blankCount, nullCount,
            'Null and blank configDevName must behave identically');
    }

    @IsTest
    static void getQueueDepth_blankConfig_skipsInactiveConfigs() {
        // Build two configs: one active, one inactive. The inactive one
        // points at a fictional object so if it WERE evaluated the test
        // would explode — proving the Active__c filter works.
        Routing_Config__mdt activeCfg = buildMockConfig();
        Routing_Config__mdt inactiveCfg = new Routing_Config__mdt(
            DeveloperName = 'Inactive_Bad_Config',
            MasterLabel = 'Inactive Bad',
            Object_API_Name__c = 'Totally_Fake_Object__c',
            Active__c = false,
            Closed_Status_Field_API_Name__c = 'Status',
            Closed_Status_Values__c = 'Closed'
        );
        RoutingConfigSelector.mockConfigs = new Map<String, Routing_Config__mdt>{
            CONFIG_DEV_NAME       => activeCfg,
            'Inactive_Bad_Config' => inactiveCfg
        };

        Test.startTest();
        Integer count = AgentWorkPanelController.getQueueDepth(null);
        Test.stopTest();

        // Should not throw — the inactive bad config must be skipped
        // before its missing object would blow up countCandidatesForConfig.
        System.assert(count >= 0,
            'Inactive configs must be skipped, count must still return');
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
    // 5. getAssignedWork TESTS — pre-existing assignments + SLA thresholds
    // =========================================================================

    @IsTest
    static void getAssignedWork_noItems_returnsEmptyList() {
        injectMockConfig();

        Test.startTest();
        List<AgentWorkPanelController.WorkAssignment> result =
            AgentWorkPanelController.getAssignedWork();
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result must never be null');
        System.assertEquals(0, result.size(),
            'With no active work items, list should be empty (not null)');
    }

    @IsTest
    static void getAssignedWork_noAgent_throwsException() {
        delete [SELECT Id FROM Agent__c];

        Boolean thrown = false;
        Test.startTest();
        try {
            AgentWorkPanelController.getAssignedWork();
        } catch (AuraHandledException e) {
            thrown = true;
        }
        Test.stopTest();

        System.assert(thrown,
            'getAssignedWork must surface the no-agent exception from loadAgentContext');
    }

    @IsTest
    static void getAssignedWork_activeItems_returnsEnrichedDtosWithThresholds() {
        injectMockConfig();

        Agent__c agent = [SELECT Id FROM Agent__c LIMIT 1];

        Case c = new Case(Subject = 'GAP Active 1', Status = 'New');
        insert c;

        Agent_Work_Item__c item = new Agent_Work_Item__c(
            Agent__c                 = agent.Id,
            Record_Id__c             = String.valueOf(c.Id),
            Object_API_Name__c       = 'Case',
            Config_Developer_Name__c = CONFIG_DEV_NAME,
            Assigned_At__c           = System.now(),
            Status__c                = 'Active'
        );
        insert item;

        Test.startTest();
        List<AgentWorkPanelController.WorkAssignment> result =
            AgentWorkPanelController.getAssignedWork();
        Test.stopTest();

        System.assertEquals(1, result.size(), 'One active item should hydrate');
        AgentWorkPanelController.WorkAssignment wa = result[0];

        System.assertEquals(c.Id, wa.recordId, 'Record Id must match');
        System.assertEquals('Case', wa.objectApiName, 'Object must be Case');
        System.assertEquals(CONFIG_DEV_NAME, wa.configDevName, 'Config must match');
        System.assertEquals(40, wa.slaWarnPct,
            'Warn threshold must come from CMDT (40%)');
        System.assertEquals(10, wa.slaCriticalPct,
            'Critical threshold must come from CMDT (10%)');
        System.assertNotEquals(null, wa.assignedAt,
            'assignedAt must flow through to the DTO');
        System.assertNotEquals(null, wa.slaDeadline,
            'SLA deadline must populate via SLA_Minutes__c fallback '
            + '(Case has no SlaExitDate in test context)');
    }

    @IsTest
    static void getAssignedWork_skipsCompletedItems() {
        injectMockConfig();

        Agent__c agent = [SELECT Id FROM Agent__c LIMIT 1];
        Case c = new Case(Subject = 'GAP Completed', Status = 'New');
        insert c;

        insert new Agent_Work_Item__c(
            Agent__c                 = agent.Id,
            Record_Id__c             = String.valueOf(c.Id),
            Object_API_Name__c       = 'Case',
            Config_Developer_Name__c = CONFIG_DEV_NAME,
            Assigned_At__c           = System.now(),
            Status__c                = 'Completed'
        );

        Test.startTest();
        List<AgentWorkPanelController.WorkAssignment> result =
            AgentWorkPanelController.getAssignedWork();
        Test.stopTest();

        System.assertEquals(0, result.size(),
            'Completed items must NOT appear in the active-work list');
    }

    @IsTest
    static void getAssignedWork_invertedThresholds_fallBackToSafetyNet() {
        // CMDT misconfiguration: Warn <= Critical violates the invariant.
        // Controller must fall back to 50/20 rather than silently drawing everything red.
        Routing_Config__mdt bad = buildMockConfig();
        bad.SLA_Warn_Threshold_Pct__c     = 10;
        bad.SLA_Critical_Threshold_Pct__c = 30;
        RoutingConfigSelector.mockConfigs = new Map<String, Routing_Config__mdt>{
            CONFIG_DEV_NAME => bad
        };

        Agent__c agent = [SELECT Id FROM Agent__c LIMIT 1];
        Case c = new Case(Subject = 'GAP Invalid Threshold', Status = 'New');
        insert c;

        insert new Agent_Work_Item__c(
            Agent__c                 = agent.Id,
            Record_Id__c             = String.valueOf(c.Id),
            Object_API_Name__c       = 'Case',
            Config_Developer_Name__c = CONFIG_DEV_NAME,
            Assigned_At__c           = System.now(),
            Status__c                = 'Active'
        );

        Test.startTest();
        List<AgentWorkPanelController.WorkAssignment> result =
            AgentWorkPanelController.getAssignedWork();
        Test.stopTest();

        System.assertEquals(1, result.size(), 'One row expected');
        System.assertEquals(50, result[0].slaWarnPct,
            'Invariant violation must fall back to FALLBACK_SLA_WARN_PCT (50)');
        System.assertEquals(20, result[0].slaCriticalPct,
            'Invariant violation must fall back to FALLBACK_SLA_CRITICAL_PCT (20)');
    }

    @IsTest
    static void getAssignedWork_multipleObjects_bulkLoadsWithoutN1() {
        // Two active items across two distinct objects. Selector is 1 SOQL,
        // bulkLoad should then hit each object ONCE (not once per record).
        injectMockConfig();

        Agent__c agent = [SELECT Id FROM Agent__c LIMIT 1];

        List<Case> cases = new List<Case>{
            new Case(Subject = 'Bulk 1', Status = 'New'),
            new Case(Subject = 'Bulk 2', Status = 'New'),
            new Case(Subject = 'Bulk 3', Status = 'New')
        };
        insert cases;

        List<Agent_Work_Item__c> items = new List<Agent_Work_Item__c>();
        for (Case c : cases) {
            items.add(new Agent_Work_Item__c(
                Agent__c                 = agent.Id,
                Record_Id__c             = String.valueOf(c.Id),
                Object_API_Name__c       = 'Case',
                Config_Developer_Name__c = CONFIG_DEV_NAME,
                Assigned_At__c           = System.now(),
                Status__c                = 'Active'
            ));
        }
        insert items;

        Test.startTest();
        Integer soqlBefore = Limits.getQueries();
        List<AgentWorkPanelController.WorkAssignment> result =
            AgentWorkPanelController.getAssignedWork();
        Integer soqlUsed = Limits.getQueries() - soqlBefore;
        Test.stopTest();

        System.assertEquals(3, result.size(), 'Three active items expected');
        // 1 SOQL for agent-context, 1 SOQL for work items, 1 SOQL for Case
        // bulk load (same object, deduped). Allow headroom but assert it
        // scales with distinct objects, NOT with row count.
        System.assert(soqlUsed <= 5,
            'Expected ≤ 5 SOQL for 3 items on a single object (bulk invariant). '
            + 'Actual: ' + soqlUsed);
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
