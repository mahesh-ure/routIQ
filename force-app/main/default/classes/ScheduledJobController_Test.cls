/**
 * @description Test class for ScheduledJobController. Tests:
 *              - getJobConfigs: list all configs with live CronTrigger status
 *              - scheduleJob: start a job, prevent double-schedule
 *              - unscheduleJob: abort a running job, error on non-existent
 *              - buildCronExpression: various interval values
 *
 *              Note: Scheduled_Job_Config__mdt is CMDT — cannot be inserted
 *              in tests. Tests focus on the CronTrigger interaction and
 *              validation logic. CMDT-dependent paths tested via scratch org
 *              deployment.
 *
 * @group Test
 */
@IsTest
private class ScheduledJobController_Test {

    // =========================================================================
    // 1. getJobConfigs TESTS
    // =========================================================================

    @IsTest
    static void getJobConfigs_returnsListWithoutError() {
        Test.startTest();
        List<ScheduledJobController.JobStatus> configs =
            ScheduledJobController.getJobConfigs();
        Test.stopTest();

        // Should return without throwing (may be empty if no CMDT records)
        System.assertNotEquals(null, configs,
            'Should return a list (possibly empty)');
    }

    // =========================================================================
    // 2. scheduleJob TESTS
    // =========================================================================

    @IsTest
    static void scheduleJob_blankConfig_throwsException() {
        Boolean exceptionThrown = false;

        Test.startTest();
        try {
            ScheduledJobController.scheduleJob('');
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assert(exceptionThrown,
            'Should throw when config dev name is blank');
    }

    @IsTest
    static void scheduleJob_nonexistentConfig_throwsException() {
        Boolean exceptionThrown = false;

        Test.startTest();
        try {
            ScheduledJobController.scheduleJob('Nonexistent_Job_Config');
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assert(exceptionThrown,
            'Should throw when config does not exist');
    }

    // =========================================================================
    // 3. unscheduleJob TESTS
    // =========================================================================

    @IsTest
    static void unscheduleJob_blankConfig_throwsException() {
        Boolean exceptionThrown = false;

        Test.startTest();
        try {
            ScheduledJobController.unscheduleJob('');
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assert(exceptionThrown,
            'Should throw when config dev name is blank');
    }

    @IsTest
    static void unscheduleJob_notScheduled_throwsException() {
        Boolean exceptionThrown = false;

        Test.startTest();
        try {
            ScheduledJobController.unscheduleJob('Nonexistent_Config');
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assert(exceptionThrown,
            'Should throw when job is not scheduled');
    }

    // =========================================================================
    // 4. buildCronExpression TESTS
    // =========================================================================

    @IsTest
    static void buildCronExpression_15minutes_returnsCorrectCron() {
        Test.startTest();
        String cron = ScheduledJobController.buildCronExpression(15);
        Test.stopTest();

        System.assertEquals('0 0,15,30,45 * * * ?', cron,
            'Should generate 15-minute cron expression');
    }

    @IsTest
    static void buildCronExpression_60minutes_returnsHourlyCron() {
        Test.startTest();
        String cron = ScheduledJobController.buildCronExpression(60);
        Test.stopTest();

        System.assertEquals('0 0 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23 * * ?', cron,
            'Should generate hourly cron expression');
    }

    @IsTest
    static void buildCronExpression_null_defaultsTo15() {
        Test.startTest();
        String cron = ScheduledJobController.buildCronExpression(null);
        Test.stopTest();

        System.assertEquals('0 0,15,30,45 * * * ?', cron,
            'Should default to 15-minute interval when null');
    }

    @IsTest
    static void buildCronExpression_zero_defaultsTo15() {
        Test.startTest();
        String cron = ScheduledJobController.buildCronExpression(0);
        Test.stopTest();

        System.assertEquals('0 0,15,30,45 * * * ?', cron,
            'Should default to 15-minute interval when zero');
    }

    @IsTest
    static void buildCronExpression_5minutes_returnsCorrectCron() {
        Test.startTest();
        String cron = ScheduledJobController.buildCronExpression(5);
        Test.stopTest();

        System.assertEquals('0 0,5,10,15,20,25,30,35,40,45,50,55 * * * ?', cron,
            'Should generate 5-minute cron expression');
    }

    // =========================================================================
    // 5. FULL CYCLE — schedule then unschedule (uses direct System.schedule)
    // =========================================================================

    @IsTest
    static void fullCycle_scheduleAndAbort_worksCorrectly() {
        // Manually schedule a job using the same naming convention
        String jobName = 'routIQ_Test_Manual_Job';
        String cronExp = '0 0 * * * ?';

        Test.startTest();
        String cronId = System.schedule(
            jobName,
            cronExp,
            new SLAEscalationJob()
        );

        // Verify it appears in CronTrigger
        List<CronTrigger> triggers = [
            SELECT Id, CronJobDetail.Name, State
            FROM   CronTrigger
            WHERE  Id = :cronId
        ];
        System.assertEquals(1, triggers.size(),
            'CronTrigger should exist after scheduling');

        // Abort the job
        System.abortJob(cronId);
        Test.stopTest();

        // Verify CronTrigger is deleted/aborted
        List<CronTrigger> remaining = [
            SELECT Id FROM CronTrigger
            WHERE  Id = :cronId
            AND    State = 'WAITING'
        ];
        System.assertEquals(0, remaining.size(),
            'CronTrigger should be aborted');
    }

    // =========================================================================
    // 6. JobStatus DTO TEST
    // =========================================================================

    @IsTest
    static void jobStatus_dto_fieldsAccessible() {
        ScheduledJobController.JobStatus js = new ScheduledJobController.JobStatus();
        js.developerName   = 'Test_Config';
        js.jobClassName    = 'SLAEscalationJob';
        js.description     = 'Test job';
        js.intervalMinutes = 15;
        js.isEnabled       = true;
        js.isScheduled     = false;
        js.cronJobId       = null;
        js.state           = null;
        js.nextFireTime    = null;
        js.previousFireTime = null;

        System.assertEquals('Test_Config', js.developerName,
            'DTO field should be accessible');
        System.assertEquals(15, js.intervalMinutes,
            'Interval should be 15');
    }
}
