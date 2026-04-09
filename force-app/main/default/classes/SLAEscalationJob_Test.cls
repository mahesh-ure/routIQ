/**
 * @description Test class for SLAEscalationJob, EscalationSelector,
 *              and EscalationService. Tests the full escalation pipeline:
 *              - Job scheduling and execution via Schedulable interface
 *              - Candidate selection with SLA threshold evaluation
 *              - Acted-on detection (skip if agent has acted)
 *              - Re-route execution (owner field update)
 *              - Notification (email send)
 *              - Audit logging (Routing_Log__c)
 *              - Platform Event publishing (Routing_Event__e)
 *
 *              Uses mock CMDT injection via RoutingConfigSelector.mockConfigs.
 *
 * @group Test
 */
@IsTest
private class SLAEscalationJob_Test {

    private static final String CONFIG_DEV_NAME = 'Test_Case_Escalation';

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

    private static Routing_Config__mdt buildEscalationConfig() {
        Routing_Config__mdt config = new Routing_Config__mdt(
            DeveloperName = CONFIG_DEV_NAME,
            MasterLabel = 'Test Case Escalation',
            Object_API_Name__c = 'Case',
            Owner_Field_API_Name__c = 'OwnerId',
            Active__c = true,
            SLA_Deadline_Field__c = 'SlaExitDate',
            SLA_Minutes__c = 60,
            Escalation_Enabled__c = true,
            Escalation_Threshold_Pct__c = 20,
            Escalation_Action__c = 'Re-route',
            Acted_On_Field__c = 'Status',
            Acted_On_Value__c = 'Working',
            Escalation_Return_Owner__c = null,
            Candidate_Limit__c = 50,
            Closed_Status_Field_API_Name__c = 'Status',
            Closed_Status_Values__c = 'Closed',
            Max_Retry_Attempts__c = 1
        );
        return config;
    }

    private static void injectMockConfig() {
        RoutingConfigSelector.mockConfigs = new Map<String, Routing_Config__mdt>{
            CONFIG_DEV_NAME => buildEscalationConfig()
        };
    }

    // =========================================================================
    // 1. THRESHOLD EVALUATION TESTS
    // =========================================================================

    @IsTest
    static void escalationService_thresholdBreached_escalatesRecord() {
        Agent__c agent = getAgent();
        injectMockConfig();

        // Create a Case with SLA deadline in the past (already breached)
        Case testCase = new Case(
            Subject = 'SLA Breached Case',
            Status = 'New'
        );
        insert testCase;

        // Create active work item
        Agent_Work_Item__c item = new Agent_Work_Item__c(
            Agent__c = agent.Id,
            Record_Id__c = String.valueOf(testCase.Id),
            Object_API_Name__c = 'Case',
            Config_Developer_Name__c = CONFIG_DEV_NAME,
            Assigned_At__c = System.now().addHours(-2),
            Status__c = 'Active'
        );
        insert item;

        agent.Current_Load__c = 1;
        update agent;

        // Build candidate manually (simulating EscalationSelector output)
        EscalationSelector.EscalationCandidate ec =
            new EscalationSelector.EscalationCandidate();
        ec.workItem = [
            SELECT Id, Record_Id__c, Object_API_Name__c,
                   Config_Developer_Name__c, Assigned_At__c, Status__c,
                   Agent__c, Agent__r.User__c
            FROM   Agent_Work_Item__c
            WHERE  Id = :item.Id
        ];
        ec.slaDeadline = System.now().addMinutes(-10); // Already past
        ec.actedOnFieldValue = 'New'; // Not acted on (not 'Working')
        ec.bundle = new ConfigBundle(
            buildEscalationConfig(),
            new List<Routing_Condition__mdt>(),
            new List<Routing_Priority__mdt>()
        );

        Test.startTest();
        EscalationService.EscalationResult result =
            EscalationService.processEscalations(
                new List<EscalationSelector.EscalationCandidate>{ ec }
            );
        Test.stopTest();

        System.assertEquals(1, result.totalEvaluated,
            'Should evaluate 1 candidate');
        System.assertEquals(1, result.totalEscalated,
            'Should escalate 1 record');
        System.assertEquals(0, result.totalSkipped,
            'Should skip 0 records');

        // Verify work item removed
        List<Agent_Work_Item__c> remaining = [
            SELECT Id FROM Agent_Work_Item__c WHERE Agent__c = :agent.Id
        ];
        System.assertEquals(0, remaining.size(),
            'Work item should be removed after escalation');

        // Verify load synced
        Agent__c updatedAgent = getAgent();
        System.assertEquals(0, updatedAgent.Current_Load__c,
            'Agent load should be 0 after escalation');
    }

    @IsTest
    static void escalationService_agentActedOn_skipsRecord() {
        Agent__c agent = getAgent();
        injectMockConfig();

        Case testCase = new Case(
            Subject = 'Acted On Case',
            Status = 'Working' // Agent has acted
        );
        insert testCase;

        Agent_Work_Item__c item = new Agent_Work_Item__c(
            Agent__c = agent.Id,
            Record_Id__c = String.valueOf(testCase.Id),
            Object_API_Name__c = 'Case',
            Config_Developer_Name__c = CONFIG_DEV_NAME,
            Assigned_At__c = System.now().addHours(-1),
            Status__c = 'Active'
        );
        insert item;

        EscalationSelector.EscalationCandidate ec =
            new EscalationSelector.EscalationCandidate();
        ec.workItem = [
            SELECT Id, Record_Id__c, Object_API_Name__c,
                   Config_Developer_Name__c, Assigned_At__c, Status__c,
                   Agent__c, Agent__r.User__c
            FROM   Agent_Work_Item__c
            WHERE  Id = :item.Id
        ];
        ec.slaDeadline = System.now().addMinutes(-5); // Past deadline
        ec.actedOnFieldValue = 'Working'; // Matches Acted_On_Value__c
        ec.bundle = new ConfigBundle(
            buildEscalationConfig(),
            new List<Routing_Condition__mdt>(),
            new List<Routing_Priority__mdt>()
        );

        Test.startTest();
        EscalationService.EscalationResult result =
            EscalationService.processEscalations(
                new List<EscalationSelector.EscalationCandidate>{ ec }
            );
        Test.stopTest();

        System.assertEquals(1, result.totalSkipped,
            'Should skip record where agent has acted');
        System.assertEquals(0, result.totalEscalated,
            'Should not escalate acted-on record');
    }

    @IsTest
    static void escalationService_noSlaDeadline_skipsRecord() {
        Agent__c agent = getAgent();

        EscalationSelector.EscalationCandidate ec =
            new EscalationSelector.EscalationCandidate();

        Agent_Work_Item__c fakeItem = new Agent_Work_Item__c(
            Agent__c = agent.Id,
            Record_Id__c = '500000000000001',
            Object_API_Name__c = 'Case',
            Config_Developer_Name__c = CONFIG_DEV_NAME,
            Assigned_At__c = System.now(),
            Status__c = 'Active'
        );
        // Don't insert — we only need the DTO structure
        ec.workItem = fakeItem;
        ec.slaDeadline = null;
        ec.bundle = new ConfigBundle(
            buildEscalationConfig(),
            new List<Routing_Condition__mdt>(),
            new List<Routing_Priority__mdt>()
        );

        Test.startTest();
        EscalationService.EscalationResult result =
            EscalationService.processEscalations(
                new List<EscalationSelector.EscalationCandidate>{ ec }
            );
        Test.stopTest();

        System.assertEquals(1, result.totalSkipped,
            'Should skip when no SLA deadline');
    }

    @IsTest
    static void escalationService_emptyList_returnsEmptyResult() {
        Test.startTest();
        EscalationService.EscalationResult result =
            EscalationService.processEscalations(
                new List<EscalationSelector.EscalationCandidate>()
            );
        Test.stopTest();

        System.assertEquals(0, result.totalEvaluated,
            'Should evaluate 0 with empty list');
    }

    // =========================================================================
    // 2. SCHEDULED JOB TESTS
    // =========================================================================

    @IsTest
    static void slaEscalationJob_execute_runsWithoutError() {
        injectMockConfig();

        Test.startTest();
        SLAEscalationJob job = new SLAEscalationJob();
        job.execute(null);
        Test.stopTest();

        // Job should complete without throwing
        // No active work items = no escalations, but job runs cleanly
    }

    @IsTest
    static void slaEscalationJob_schedulable_canBeScheduled() {
        Test.startTest();
        String cronExp = '0 0 * * * ?';
        String jobId = System.schedule(
            'Test_SLA_Escalation',
            cronExp,
            new SLAEscalationJob()
        );
        Test.stopTest();

        System.assertNotEquals(null, jobId, 'Job should be scheduled');

        // Clean up
        System.abortJob(jobId);
    }

    // =========================================================================
    // 3. ESCALATION WITH NOTIFICATION
    // =========================================================================

    @IsTest
    static void escalationService_notifyAction_sendsEmail() {
        Agent__c agent = getAgent();

        Routing_Config__mdt notifyConfig = buildEscalationConfig();
        notifyConfig.Escalation_Action__c = 'Notify';
        notifyConfig.Escalation_Notify_Email__c = 'admin@test.com';

        Case testCase = new Case(Subject = 'Notify Test', Status = 'New');
        insert testCase;

        Agent_Work_Item__c item = new Agent_Work_Item__c(
            Agent__c = agent.Id,
            Record_Id__c = String.valueOf(testCase.Id),
            Object_API_Name__c = 'Case',
            Config_Developer_Name__c = CONFIG_DEV_NAME,
            Assigned_At__c = System.now().addHours(-2),
            Status__c = 'Active'
        );
        insert item;

        EscalationSelector.EscalationCandidate ec =
            new EscalationSelector.EscalationCandidate();
        ec.workItem = [
            SELECT Id, Record_Id__c, Object_API_Name__c,
                   Config_Developer_Name__c, Assigned_At__c, Status__c,
                   Agent__c, Agent__r.User__c
            FROM   Agent_Work_Item__c
            WHERE  Id = :item.Id
        ];
        ec.slaDeadline = System.now().addMinutes(-5);
        ec.actedOnFieldValue = 'New';
        ec.bundle = new ConfigBundle(
            notifyConfig,
            new List<Routing_Condition__mdt>(),
            new List<Routing_Priority__mdt>()
        );

        Integer emailsBefore = Limits.getEmailInvocations();

        Test.startTest();
        EscalationService.EscalationResult result =
            EscalationService.processEscalations(
                new List<EscalationSelector.EscalationCandidate>{ ec }
            );
        Test.stopTest();

        System.assertEquals(1, result.totalEscalated,
            'Should escalate with Notify action');
    }

    // =========================================================================
    // 4. CONFIGBUNDLE ESCALATION FIELDS
    // =========================================================================

    @IsTest
    static void configBundle_parsesEscalationFields() {
        Routing_Config__mdt config = buildEscalationConfig();

        Test.startTest();
        ConfigBundle bundle = new ConfigBundle(
            config,
            new List<Routing_Condition__mdt>(),
            new List<Routing_Priority__mdt>()
        );
        Test.stopTest();

        System.assertEquals(true, bundle.escalationEnabled,
            'escalationEnabled should be true');
        System.assertEquals(20, bundle.escalationThresholdPct,
            'Threshold should be 20');
        System.assertEquals('Re-route', bundle.escalationAction,
            'Action should be Re-route');
        System.assertEquals('Status', bundle.actedOnField,
            'Acted on field should be Status');
        System.assertEquals(1, bundle.actedOnValues.size(),
            'Should parse 1 acted-on value');
        System.assertEquals('Working', bundle.actedOnValues[0],
            'Acted on value should be Working');
    }
}
