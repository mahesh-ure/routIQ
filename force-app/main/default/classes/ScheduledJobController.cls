/**
 * @description Generic @AuraEnabled controller for managing scheduled jobs
 *              from within the routIQ app. Reads job configuration from
 *              Scheduled_Job_Config__mdt and interacts with System.schedule /
 *              System.abortJob — no anonymous Apex required from the admin.
 *
 *              Future-proof: supports any number of scheduled jobs. Each
 *              Scheduled_Job_Config__mdt record = one manageable job. Adding
 *              a new job type requires only a new CMDT record and a Schedulable
 *              Apex class — zero changes to this controller.
 *
 *              Endpoints:
 *              1. getJobConfigs()   — list all configured jobs with live status
 *              2. scheduleJob()     — start a job using its CMDT config
 *              3. unscheduleJob()   — abort a running job
 *
 *              Security:
 *              - Job instantiation via Type.forName() — validated against CMDT
 *                whitelist (only classes registered in Scheduled_Job_Config__mdt).
 *              - No user-supplied class names accepted.
 *              - Requires ManageScheduledApex or Admin permissions.
 *
 * @group Entry
 */
public with sharing class ScheduledJobController {

    private static final String CLS = 'ScheduledJobController';

    // Job name prefix for namespace safety
    private static final String JOB_PREFIX = 'routIQ_';

    // =========================================================================
    // INNER CLASS — Job status DTO for LWC
    // =========================================================================

    /**
     * @description DTO combining CMDT configuration with live CronTrigger
     *              status. Returned to LWC for display in the job management UI.
     */
    public class JobStatus {
        @AuraEnabled public String  developerName;
        @AuraEnabled public String  jobClassName;
        @AuraEnabled public String  description;
        @AuraEnabled public Decimal intervalMinutes;
        @AuraEnabled public Boolean isEnabled;
        @AuraEnabled public Boolean isScheduled;
        @AuraEnabled public String  cronJobId;
        @AuraEnabled public String  state;
        @AuraEnabled public Datetime nextFireTime;
        @AuraEnabled public Datetime previousFireTime;
    }

    // =========================================================================
    // 1. getJobConfigs — list all jobs with live status
    // =========================================================================

    /**
     * @description Returns all Scheduled_Job_Config__mdt records enriched with
     *              live CronTrigger status. 0 SOQL for CMDT + 1 SOQL for
     *              CronTrigger lookup.
     *
     * @return List of JobStatus DTOs
     */
    @AuraEnabled(cacheable=true)
    public static List<JobStatus> getJobConfigs() {
        // Load CMDT (0 SOQL — platform-cached)
        Map<String, Scheduled_Job_Config__mdt> configs =
            Scheduled_Job_Config__mdt.getAll();

        // Query active CronTriggers for our jobs (1 SOQL)
        Map<String, CronTrigger> cronByName = getCronTriggerMap();

        List<JobStatus> result = new List<JobStatus>();
        for (String devName : configs.keySet()) {
            Scheduled_Job_Config__mdt cfg = configs.get(devName);
            JobStatus js = new JobStatus();
            js.developerName   = devName;
            js.jobClassName    = cfg.Job_Class_Name__c;
            js.description     = cfg.Description__c;
            js.intervalMinutes = cfg.Interval_Minutes__c;
            js.isEnabled       = (cfg.Is_Enabled__c == true);

            // Check live status from CronTrigger
            String jobName = JOB_PREFIX + devName;
            CronTrigger ct = cronByName.get(jobName);
            if (ct != null) {
                js.isScheduled       = true;
                js.cronJobId         = ct.Id;
                js.state             = ct.State;
                js.nextFireTime      = ct.NextFireTime;
                js.previousFireTime  = ct.PreviousFireTime;
            } else {
                js.isScheduled = false;
            }

            result.add(js);
        }

        return result;
    }

    // =========================================================================
    // 2. scheduleJob — start a job
    // =========================================================================

    /**
     * @description Schedules a job using its Scheduled_Job_Config__mdt config.
     *              Builds a cron expression from the Interval_Minutes__c value.
     *              Validates the job class exists and implements Schedulable.
     *
     * @param configDevName DeveloperName of the Scheduled_Job_Config__mdt record
     * @return The CronTrigger ID of the scheduled job
     * @throws AuraHandledException on validation failure
     */
    @AuraEnabled
    public static String scheduleJob(String configDevName) {
        // ── Load and validate config ─────────────────────────────────────
        Scheduled_Job_Config__mdt cfg = getValidatedConfig(configDevName);

        // ── Check not already scheduled ──────────────────────────────────
        String jobName = JOB_PREFIX + configDevName;
        Map<String, CronTrigger> cronByName = getCronTriggerMap();
        if (cronByName.containsKey(jobName)) {
            throw new AuraHandledException(
                'Job "' + configDevName + '" is already scheduled. '
                + 'Unschedule it first before rescheduling.'
            );
        }

        // ── Instantiate the Schedulable class ────────────────────────────
        String className = cfg.Job_Class_Name__c;
        Type jobType = Type.forName(className);
        if (jobType == null) {
            throw new AuraHandledException(
                'Apex class "' + className + '" not found. '
                + 'Verify the class name in the Scheduled Job Config.'
            );
        }

        Object instance = jobType.newInstance();
        if (!(instance instanceof Schedulable)) {
            throw new AuraHandledException(
                'Class "' + className + '" does not implement Schedulable.'
            );
        }

        // ── Build cron expression from interval ──────────────────────────
        Integer intervalMinutes = (cfg.Interval_Minutes__c != null)
            ? cfg.Interval_Minutes__c.intValue()
            : 15;

        String cronExp = buildCronExpression(intervalMinutes);

        // ── Schedule the job ─────────────────────────────────────────────
        try {
            String cronId = System.schedule(
                jobName,
                cronExp,
                (Schedulable) instance
            );

            Logger.info('Scheduled job | name=' + jobName
                    + ' | class=' + className
                    + ' | interval=' + intervalMinutes + 'min'
                    + ' | cron=' + cronExp)
                .category(Logger.Category.ENGINE)
                .inClass(CLS).inMethod('scheduleJob')
                .log();

            return cronId;

        } catch (Exception ex) {
            throw new AuraHandledException(
                'Failed to schedule job: ' + ex.getMessage()
            );
        }
    }

    // =========================================================================
    // 3. unscheduleJob — abort a running job
    // =========================================================================

    /**
     * @description Aborts a scheduled job by its config developer name.
     *              Looks up the CronTrigger by the standardized job name
     *              (routIQ_ + configDevName) and calls System.abortJob().
     *
     * @param configDevName DeveloperName of the Scheduled_Job_Config__mdt record
     * @return 'OK' on success
     * @throws AuraHandledException if the job is not found or abort fails
     */
    @AuraEnabled
    public static String unscheduleJob(String configDevName) {
        if (String.isBlank(configDevName)) {
            throw new AuraHandledException('Config developer name is required.');
        }

        String jobName = JOB_PREFIX + configDevName;
        Map<String, CronTrigger> cronByName = getCronTriggerMap();
        CronTrigger ct = cronByName.get(jobName);

        if (ct == null) {
            throw new AuraHandledException(
                'Job "' + configDevName + '" is not currently scheduled.'
            );
        }

        try {
            System.abortJob(ct.Id);

            Logger.info('Unscheduled job | name=' + jobName)
                .category(Logger.Category.ENGINE)
                .inClass(CLS).inMethod('unscheduleJob')
                .log();

            return 'OK';

        } catch (Exception ex) {
            throw new AuraHandledException(
                'Failed to unschedule job: ' + ex.getMessage()
            );
        }
    }

    // =========================================================================
    // PRIVATE HELPERS
    // =========================================================================

    /**
     * @description Loads and validates a Scheduled_Job_Config__mdt record.
     *              Throws AuraHandledException on validation failure.
     */
    private static Scheduled_Job_Config__mdt getValidatedConfig(
        String configDevName
    ) {
        if (String.isBlank(configDevName)) {
            throw new AuraHandledException('Config developer name is required.');
        }

        Map<String, Scheduled_Job_Config__mdt> configs =
            Scheduled_Job_Config__mdt.getAll();
        Scheduled_Job_Config__mdt cfg = configs.get(configDevName);

        if (cfg == null) {
            throw new AuraHandledException(
                'Scheduled Job Config "' + configDevName + '" not found.'
            );
        }

        if (cfg.Is_Enabled__c != true) {
            throw new AuraHandledException(
                'Job "' + configDevName + '" is disabled. '
                + 'Enable it in Scheduled Job Config before scheduling.'
            );
        }

        if (String.isBlank(cfg.Job_Class_Name__c)) {
            throw new AuraHandledException(
                'Job class name is not configured for "' + configDevName + '".'
            );
        }

        return cfg;
    }

    /**
     * @description Queries CronTrigger records for routIQ jobs and returns
     *              them keyed by CronJobDetail.Name. 1 SOQL.
     */
    private static Map<String, CronTrigger> getCronTriggerMap() {
        List<CronTrigger> triggers = [
            SELECT Id, State, NextFireTime, PreviousFireTime,
                   CronJobDetail.Name
            FROM   CronTrigger
            WHERE  CronJobDetail.Name LIKE 'routIQ_%'
        ];

        Map<String, CronTrigger> result = new Map<String, CronTrigger>();
        for (CronTrigger ct : triggers) {
            if (ct.CronJobDetail != null) {
                result.put(ct.CronJobDetail.Name, ct);
            }
        }
        return result;
    }

    /**
     * @description Builds a cron expression from an interval in minutes.
     *              Supports common intervals: 1, 5, 10, 15, 20, 30, 60.
     *              For non-standard intervals, defaults to the nearest
     *              standard interval.
     *
     * @param intervalMinutes The desired run interval in minutes
     * @return A valid Salesforce cron expression string
     */
    /**
     * @description Builds a valid Salesforce cron expression from an interval
     *              in minutes. System.schedule() requires explicit integers
     *              in the seconds/minutes fields — no `0/N` syntax.
     *
     *              For intervals < 60: generates comma-separated minute values.
     *              For intervals >= 60: runs at minute 0 every N hours.
     *
     * @param intervalMinutes The desired run interval in minutes
     * @return A valid Salesforce cron expression string
     */
    @TestVisible
    private static String buildCronExpression(Integer intervalMinutes) {
        if (intervalMinutes == null || intervalMinutes <= 0) {
            intervalMinutes = 15;
        }

        // For hourly or greater intervals
        if (intervalMinutes >= 60) {
            Integer hours = intervalMinutes / 60;
            if (hours <= 0) hours = 1;
            // Run at minute 0, every N hours
            List<String> hourValues = new List<String>();
            for (Integer h = 0; h < 24; h += hours) {
                hourValues.add(String.valueOf(h));
            }
            return '0 0 ' + String.join(hourValues, ',') + ' * * ?';
        }

        // For sub-hourly: build comma-separated minute list
        List<String> minuteValues = new List<String>();
        for (Integer m = 0; m < 60; m += intervalMinutes) {
            minuteValues.add(String.valueOf(m));
        }
        return '0 ' + String.join(minuteValues, ',') + ' * * * ?';
    }
}
