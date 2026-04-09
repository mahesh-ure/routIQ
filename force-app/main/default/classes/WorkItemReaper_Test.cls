/**
 * @description Test class for WorkItemReaper and WorkItemReaperJob.
 *              Verifies the zombie-cleanup contract:
 *              - Closed source record → work item reaped
 *              - Deleted source record → work item reaped
 *              - Open source record → work item preserved
 *              - Agent load synced after reaping
 *              - Reaper handles empty input gracefully
 *              - Scheduled job wrapper executes without error
 *
 * @group Test
 */
@IsTest
private class WorkItemReaper_Test {

    private static final String CONFIG_DEV_NAME = 'Test_Case_Reaper';

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
            SELECT Id, Current_Load__c, User__c
            FROM   Agent__c
            WHERE  User__c = :UserInfo.getUserId()
            LIMIT  1
        ];
    }

    private static Case insertCase(String subject, String status) {
        Case c = new Case(Subject = subject, Status = status);
        insert c;
        return c;
    }

    private static Agent_Work_Item__c insertWorkItem(
        Id agentId, Id recordId
    ) {
        Agent_Work_Item__c item = new Agent_Work_Item__c(
            Agent__c                 = agentId,
            Record_Id__c             = String.valueOf(recordId),
            Object_API_Name__c       = 'Case',
            Config_Developer_Name__c = CONFIG_DEV_NAME,
            Assigned_At__c           = System.now(),
            Status__c                = 'Active'
        );
        insert item;
        return item;
    }

    private static void injectMockConfig() {
        Routing_Config__mdt cfg = new Routing_Config__mdt(
            DeveloperName           = CONFIG_DEV_NAME,
            MasterLabel             = 'Test Case Reaper',
            Object_API_Name__c      = 'Case',
            Owner_Field_API_Name__c = 'OwnerId',
            Active__c               = true,
            Closed_Status_Field_API_Name__c = 'Status',
            Closed_Status_Values__c = 'Closed',
            Candidate_Limit__c      = 50,
            Max_Retry_Attempts__c   = 1
        );
        RoutingConfigSelector.mockConfigs =
            new Map<String, Routing_Config__mdt>{ CONFIG_DEV_NAME => cfg };
    }

    // =========================================================================
    // 1. CORE REAP — CLOSED SOURCE RECORD
    // =========================================================================

    @IsTest
    static void reapForAgent_closedSourceRecord_reapsWorkItem() {
        Agent__c agent = getAgent();
        injectMockConfig();

        // Create a closed Case and a work item pointing at it
        Case closedCase = insertCase('Closed Zombie', 'Closed');
        insertWorkItem(agent.Id, closedCase.Id);

        // Set load manually so we can verify sync
        agent.Current_Load__c = 1;
        update agent;

        Test.startTest();
        Integer reaped = WorkItemReaper.reapForAgent(agent.Id);
        Test.stopTest();

        System.assertEquals(1, reaped,
            'Should reap exactly 1 closed work item');

        // Work item removed
        List<Agent_Work_Item__c> remaining = [
            SELECT Id FROM Agent_Work_Item__c WHERE Agent__c = :agent.Id
        ];
        System.assertEquals(0, remaining.size(),
            'Closed work item should be deleted');

        // Load synced to 0
        Agent__c updated = getAgent();
        System.assertEquals(0, updated.Current_Load__c,
            'Current_Load__c should drop to 0 after reap');
    }

    // =========================================================================
    // 2. CORE REAP — DELETED SOURCE RECORD
    // =========================================================================

    @IsTest
    static void reapForAgent_deletedSourceRecord_reapsWorkItem() {
        Agent__c agent = getAgent();
        injectMockConfig();

        Case c = insertCase('Will Be Deleted', 'New');
        insertWorkItem(agent.Id, c.Id);

        // Delete the source Case — work item is now an orphan
        delete c;

        Test.startTest();
        Integer reaped = WorkItemReaper.reapForAgent(agent.Id);
        Test.stopTest();

        System.assertEquals(1, reaped,
            'Should reap work item whose source was deleted');

        List<Agent_Work_Item__c> remaining = [
            SELECT Id FROM Agent_Work_Item__c WHERE Agent__c = :agent.Id
        ];
        System.assertEquals(0, remaining.size(),
            'Orphan work item should be deleted');
    }

    // =========================================================================
    // 3. OPEN RECORD PRESERVED
    // =========================================================================

    @IsTest
    static void reapForAgent_openRecord_preservesWorkItem() {
        Agent__c agent = getAgent();
        injectMockConfig();

        Case openCase = insertCase('Still Open', 'New');
        insertWorkItem(agent.Id, openCase.Id);

        Test.startTest();
        Integer reaped = WorkItemReaper.reapForAgent(agent.Id);
        Test.stopTest();

        System.assertEquals(0, reaped,
            'Should not reap open work items');

        List<Agent_Work_Item__c> remaining = [
            SELECT Id FROM Agent_Work_Item__c WHERE Agent__c = :agent.Id
        ];
        System.assertEquals(1, remaining.size(),
            'Open work item should survive');
    }

    // =========================================================================
    // 4. MIXED BATCH — CLOSED + OPEN
    // =========================================================================

    @IsTest
    static void reapForAgent_mixedBatch_reapsOnlyClosed() {
        Agent__c agent = getAgent();
        injectMockConfig();

        Case open1   = insertCase('Open 1',   'New');
        Case open2   = insertCase('Open 2',   'Working');
        Case closed1 = insertCase('Closed 1', 'Closed');
        Case closed2 = insertCase('Closed 2', 'Closed');

        insertWorkItem(agent.Id, open1.Id);
        insertWorkItem(agent.Id, open2.Id);
        insertWorkItem(agent.Id, closed1.Id);
        insertWorkItem(agent.Id, closed2.Id);

        agent.Current_Load__c = 4;
        update agent;

        Test.startTest();
        Integer reaped = WorkItemReaper.reapForAgent(agent.Id);
        Test.stopTest();

        System.assertEquals(2, reaped,
            'Should reap only the 2 closed items');

        List<Agent_Work_Item__c> remaining = [
            SELECT Id, Record_Id__c FROM Agent_Work_Item__c
            WHERE Agent__c = :agent.Id
        ];
        System.assertEquals(2, remaining.size(),
            'Open items should remain');

        Agent__c updated = getAgent();
        System.assertEquals(2, updated.Current_Load__c,
            'Load should drop to 2 (the remaining open items)');
    }

    // =========================================================================
    // 5. NULL / EMPTY INPUT HANDLING
    // =========================================================================

    @IsTest
    static void reapForAgent_nullId_returnsZero() {
        Test.startTest();
        Integer reaped = WorkItemReaper.reapForAgent(null);
        Test.stopTest();

        System.assertEquals(0, reaped, 'Null agentId should return 0');
    }

    @IsTest
    static void reapForAgent_noWorkItems_returnsZero() {
        Agent__c agent = getAgent();

        Test.startTest();
        Integer reaped = WorkItemReaper.reapForAgent(agent.Id);
        Test.stopTest();

        System.assertEquals(0, reaped,
            'Agent with no work items should return 0');
    }

    // =========================================================================
    // 6. reapForCurrentUser — UserInfo resolution path
    // =========================================================================

    @IsTest
    static void reapForCurrentUser_resolvesAgentFromUser() {
        Agent__c agent = getAgent();
        injectMockConfig();

        Case closed = insertCase('User-scoped reap', 'Closed');
        insertWorkItem(agent.Id, closed.Id);

        Test.startTest();
        Integer reaped = WorkItemReaper.reapForCurrentUser();
        Test.stopTest();

        System.assertEquals(1, reaped,
            'reapForCurrentUser should reap the current user agent items');
    }

    // =========================================================================
    // 7. reapAll — org-wide sweep
    // =========================================================================

    @IsTest
    static void reapAll_orgWideSweep_reapsAllZombies() {
        Agent__c agent = getAgent();
        injectMockConfig();

        Case c1 = insertCase('Zombie A', 'Closed');
        Case c2 = insertCase('Zombie B', 'Closed');
        Case c3 = insertCase('Alive',    'New');
        insertWorkItem(agent.Id, c1.Id);
        insertWorkItem(agent.Id, c2.Id);
        insertWorkItem(agent.Id, c3.Id);

        Test.startTest();
        Integer reaped = WorkItemReaper.reapAll();
        Test.stopTest();

        System.assertEquals(2, reaped,
            'reapAll should reap both closed work items');
    }

    // =========================================================================
    // 8. SCHEDULED JOB WRAPPER
    // =========================================================================

    @IsTest
    static void workItemReaperJob_execute_runsWithoutError() {
        injectMockConfig();

        Test.startTest();
        WorkItemReaperJob job = new WorkItemReaperJob();
        job.execute(null);
        Test.stopTest();
        // No assertion — just verifying the job runs cleanly
    }

    @IsTest
    static void workItemReaperJob_schedulable_canBeScheduled() {
        Test.startTest();
        String jobId = System.schedule(
            'Test_Work_Item_Reaper',
            '0 0 * * * ?',
            new WorkItemReaperJob()
        );
        Test.stopTest();

        System.assertNotEquals(null, jobId, 'Job should schedule');
        System.abortJob(jobId);
    }

    // =========================================================================
    // 9. METADATA-DRIVEN CLOSED STATUS FIELD — OPPORTUNITY / STAGENAME
    // =========================================================================

    /**
     * @description Verifies the reaper respects per-config
     *              Closed_Status_Field_API_Name__c. Here the config targets
     *              Opportunity and uses StageName (not Status), so a
     *              'Closed Won' Opp must be reaped without the reaper
     *              needing any hardcoded Opportunity knowledge.
     */
    @IsTest
    static void reapForAgent_opportunityStageName_reapsClosedStage() {
        Agent__c agent = getAgent();

        // Inject an Opportunity-targeted config
        String oppConfigName = 'Test_Opp_Reaper';
        Routing_Config__mdt oppCfg = new Routing_Config__mdt(
            DeveloperName                   = oppConfigName,
            MasterLabel                     = 'Test Opp Reaper',
            Object_API_Name__c              = 'Opportunity',
            Owner_Field_API_Name__c         = 'OwnerId',
            Active__c                       = true,
            Closed_Status_Field_API_Name__c = 'StageName',
            Closed_Status_Values__c         = 'Closed Won,Closed Lost',
            Candidate_Limit__c              = 50,
            Max_Retry_Attempts__c           = 1
        );
        RoutingConfigSelector.mockConfigs =
            new Map<String, Routing_Config__mdt>{ oppConfigName => oppCfg };

        // Create an Opportunity in a closed stage
        Opportunity opp = new Opportunity(
            Name      = 'Zombie Opp',
            StageName = 'Closed Won',
            CloseDate = Date.today()
        );
        insert opp;

        // Create a work item tied to the Opp config
        Agent_Work_Item__c item = new Agent_Work_Item__c(
            Agent__c                 = agent.Id,
            Record_Id__c             = String.valueOf(opp.Id),
            Object_API_Name__c       = 'Opportunity',
            Config_Developer_Name__c = oppConfigName,
            Assigned_At__c           = System.now(),
            Status__c                = 'Active'
        );
        insert item;

        Test.startTest();
        Integer reaped = WorkItemReaper.reapForAgent(agent.Id);
        Test.stopTest();

        System.assertEquals(1, reaped,
            'Closed Won Opportunity zombie should be reaped via StageName');

        List<Agent_Work_Item__c> remaining = [
            SELECT Id FROM Agent_Work_Item__c WHERE Agent__c = :agent.Id
        ];
        System.assertEquals(0, remaining.size(),
            'No Opp work items should remain');
    }

    // =========================================================================
    // 10. GRACEFUL DEGRADATION — CLOSED FIELD NOT CONFIGURED
    // =========================================================================

    /**
     * @description When the new Closed_Status_Field_API_Name__c is blank,
     *              closure detection is intentionally disabled — only
     *              deletion detection applies. Open Cases are preserved and
     *              closed Cases are preserved (admin has opted out of
     *              status-based cleanup).
     */
    @IsTest
    static void reapForAgent_blankClosedField_preservesClosedRecord() {
        Agent__c agent = getAgent();

        // Inject a config WITHOUT Closed_Status_Field_API_Name__c
        Routing_Config__mdt cfg = new Routing_Config__mdt(
            DeveloperName                   = CONFIG_DEV_NAME,
            MasterLabel                     = 'Test Case Reaper (no closed field)',
            Object_API_Name__c              = 'Case',
            Owner_Field_API_Name__c         = 'OwnerId',
            Active__c                       = true,
            // Closed_Status_Field_API_Name__c intentionally omitted
            Closed_Status_Values__c         = 'Closed',
            Candidate_Limit__c              = 50,
            Max_Retry_Attempts__c           = 1
        );
        RoutingConfigSelector.mockConfigs =
            new Map<String, Routing_Config__mdt>{ CONFIG_DEV_NAME => cfg };

        Case closed = insertCase('Still "Closed" but no field', 'Closed');
        insertWorkItem(agent.Id, closed.Id);

        Test.startTest();
        Integer reaped = WorkItemReaper.reapForAgent(agent.Id);
        Test.stopTest();

        System.assertEquals(0, reaped,
            'No closed field configured → closure detection disabled');

        List<Agent_Work_Item__c> remaining = [
            SELECT Id FROM Agent_Work_Item__c WHERE Agent__c = :agent.Id
        ];
        System.assertEquals(1, remaining.size(),
            'Work item should survive when closure detection is disabled');
    }

    /**
     * @description Even with no closed field, deletion detection must still
     *              work — the reaper's safety net for orphaned work items
     *              does not depend on closed-status config.
     */
    @IsTest
    static void reapForAgent_blankClosedField_stillReapsDeleted() {
        Agent__c agent = getAgent();

        Routing_Config__mdt cfg = new Routing_Config__mdt(
            DeveloperName           = CONFIG_DEV_NAME,
            MasterLabel             = 'Test Case Reaper (no closed field)',
            Object_API_Name__c      = 'Case',
            Owner_Field_API_Name__c = 'OwnerId',
            Active__c               = true,
            Candidate_Limit__c      = 50,
            Max_Retry_Attempts__c   = 1
        );
        RoutingConfigSelector.mockConfigs =
            new Map<String, Routing_Config__mdt>{ CONFIG_DEV_NAME => cfg };

        Case c = insertCase('Delete me', 'New');
        insertWorkItem(agent.Id, c.Id);
        delete c;

        Test.startTest();
        Integer reaped = WorkItemReaper.reapForAgent(agent.Id);
        Test.stopTest();

        System.assertEquals(1, reaped,
            'Deletion detection must still work without closed field config');
    }

    // =========================================================================
    // 11. ZOMBIE REGRESSION — THE EXACT BUG REPORTED
    // =========================================================================

    /**
     * @description Reproduces the user-reported bug:
     *              - Agent has 3 existing Active work items (zombies)
     *              - Admin manually sets Current_Load__c = 0 on Agent record
     *              - On next NBA pull, load inflated to 4 instead of 1
     *
     *              After this fix: reapForCurrentUser() cleans the zombies
     *              BEFORE the new assignment, so load lands at the correct
     *              value (1 when all 3 prior records are closed).
     */
    @IsTest
    static void zombieRegression_manualLoadResetWithClosedZombies_reapsClean() {
        Agent__c agent = getAgent();
        injectMockConfig();

        // Simulate 3 zombie work items whose source Cases are closed
        Case z1 = insertCase('Zombie 1', 'Closed');
        Case z2 = insertCase('Zombie 2', 'Closed');
        Case z3 = insertCase('Zombie 3', 'Closed');
        insertWorkItem(agent.Id, z1.Id);
        insertWorkItem(agent.Id, z2.Id);
        insertWorkItem(agent.Id, z3.Id);

        // Admin manually resets the counter on the Agent record
        agent.Current_Load__c = 0;
        update agent;

        Test.startTest();
        // Reaper runs before any new assignment (simulates pre-pull hook)
        Integer reaped = WorkItemReaper.reapForAgent(agent.Id);
        Test.stopTest();

        System.assertEquals(3, reaped,
            'All 3 closed zombies should be reaped');

        Agent__c cleaned = getAgent();
        System.assertEquals(0, cleaned.Current_Load__c,
            'Load should be 0 after reaping zombies — '
            + 'next NBA click will then correctly land at 1');

        List<Agent_Work_Item__c> remaining = [
            SELECT Id FROM Agent_Work_Item__c WHERE Agent__c = :agent.Id
        ];
        System.assertEquals(0, remaining.size(),
            'No zombies should survive the reap');
    }
}
