/**
 * @description Generic controller for managing scheduled jobs from the routIQ app.
 *              Reads config from Scheduled_Job_Config__mdt, interacts with System.schedule/abortJob.
 *              Supports any number of jobs -- each CMDT record = one manageable job.
 * @group Entry
 */
public with sharing class ScheduledJobController {

    private static final String CLS = 'ScheduledJobController';
    private static final String JOB_PREFIX = 'routIQ_';

    /** @description DTO combining CMDT configuration with live CronTrigger status for LWC. */
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

    /**
     * @description Returns all Scheduled_Job_Config__mdt records enriched with live CronTrigger status.
     * @return List of JobStatus DTOs
     */
    @AuraEnabled(cacheable=true)
    public static List<JobStatus> getJobConfigs() {
        Map<String, Scheduled_Job_Config__mdt> configs = Scheduled_Job_Config__mdt.getAll();
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

            String jobName = JOB_PREFIX + devName;
            CronTrigger ct = cronByName.get(jobName);
            if (ct != null) {
                js.isScheduled      = true;
                js.cronJobId        = ct.Id;
                js.state            = ct.State;
                js.nextFireTime     = ct.NextFireTime;
                js.previousFireTime = ct.PreviousFireTime;
            } else {
                js.isScheduled = false;
            }

            result.add(js);
        }

        return result;
    }

    /**
     * @description Schedules a job using its Scheduled_Job_Config__mdt config.
     * @param configDevName DeveloperName of the Scheduled_Job_Config__mdt record
     * @return The CronTrigger ID of the scheduled job
     */
    @AuraEnabled
    public static String scheduleJob(String configDevName) {
        Scheduled_Job_Config__mdt cfg = getValidatedConfig(configDevName);

        String jobName = JOB_PREFIX + configDevName;
        Map<String, CronTrigger> cronByName = getCronTriggerMap();
        if (cronByName.containsKey(jobName)) {
            throw new AuraHandledException(
                String.format(System.Label.URE_JOB_ALREADY_SCHEDULED, new List<Object>{configDevName})
            );
        }

        String className = cfg.Job_Class_Name__c;
        Type jobType = Type.forName(className);
        if (jobType == null) {
            throw new AuraHandledException(
                String.format(System.Label.URE_JOB_CLASS_NOT_FOUND, new List<Object>{className})
            );
        }

        Object instance = jobType.newInstance();
        if (!(instance instanceof Schedulable)) {
            throw new AuraHandledException(
                String.format(System.Label.URE_JOB_NOT_SCHEDULABLE, new List<Object>{className})
            );
        }

        Integer intervalMinutes = (cfg.Interval_Minutes__c != null)
            ? cfg.Interval_Minutes__c.intValue()
            : 15;

        String cronExp = buildCronExpression(intervalMinutes);

        try {
            String cronId = System.schedule(jobName, cronExp, (Schedulable) instance);

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
                String.format(System.Label.URE_JOB_SCHEDULE_FAILED, new List<Object>{ex.getMessage()})
            );
        }
    }

    /**
     * @description Aborts a scheduled job by its config developer name.
     * @param configDevName DeveloperName of the Scheduled_Job_Config__mdt record
     * @return 'OK' on success
     */
    @AuraEnabled
    public static String unscheduleJob(String configDevName) {
        if (String.isBlank(configDevName)) {
            throw new AuraHandledException(System.Label.URE_JOB_CONFIG_REQUIRED);
        }

        String jobName = JOB_PREFIX + configDevName;
        Map<String, CronTrigger> cronByName = getCronTriggerMap();
        CronTrigger ct = cronByName.get(jobName);

        if (ct == null) {
            throw new AuraHandledException(
                String.format(System.Label.URE_JOB_NOT_SCHEDULED, new List<Object>{configDevName})
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
                String.format(System.Label.URE_JOB_UNSCHEDULE_FAILED, new List<Object>{ex.getMessage()})
            );
        }
    }

    /**
     * @description Loads and validates a Scheduled_Job_Config__mdt record.
     * @throws AuraHandledException on validation failure
     */
    private static Scheduled_Job_Config__mdt getValidatedConfig(String configDevName) {
        if (String.isBlank(configDevName)) {
            throw new AuraHandledException(System.Label.URE_JOB_CONFIG_REQUIRED);
        }

        Map<String, Scheduled_Job_Config__mdt> configs = Scheduled_Job_Config__mdt.getAll();
        Scheduled_Job_Config__mdt cfg = configs.get(configDevName);

        if (cfg == null) {
            throw new AuraHandledException(
                String.format(System.Label.URE_JOB_CONFIG_NOT_FOUND, new List<Object>{configDevName})
            );
        }

        if (cfg.Is_Enabled__c != true) {
            throw new AuraHandledException(
                String.format(System.Label.URE_JOB_DISABLED, new List<Object>{configDevName})
            );
        }

        if (String.isBlank(cfg.Job_Class_Name__c)) {
            throw new AuraHandledException(
                String.format(System.Label.URE_JOB_CLASS_NOT_CONFIGURED, new List<Object>{configDevName})
            );
        }

        return cfg;
    }

    /**
     * @description Queries CronTrigger records for routIQ jobs, keyed by CronJobDetail.Name. 1 SOQL.
     */
    private static Map<String, CronTrigger> getCronTriggerMap() {
        List<CronTrigger> triggers = [
            SELECT Id, State, NextFireTime, PreviousFireTime, CronJobDetail.Name
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
     * @description Builds a valid Salesforce cron expression from an interval in minutes.
     *              For intervals < 60: comma-separated minute values. For >= 60: every N hours.
     * @param intervalMinutes The desired run interval in minutes
     * @return A valid Salesforce cron expression string
     */
    @TestVisible
    private static String buildCronExpression(Integer intervalMinutes) {
        if (intervalMinutes == null || intervalMinutes <= 0) {
            intervalMinutes = 15;
        }

        if (intervalMinutes >= 60) {
            Integer hours = intervalMinutes / 60;
            if (hours <= 0) hours = 1;
            List<String> hourValues = new List<String>();
            for (Integer h = 0; h < 24; h += hours) {
                hourValues.add(String.valueOf(h));
            }
            return '0 0 ' + String.join(hourValues, ',') + ' * * ?';
        }

        List<String> minuteValues = new List<String>();
        for (Integer m = 0; m < 60; m += intervalMinutes) {
            minuteValues.add(String.valueOf(m));
        }
        return '0 ' + String.join(minuteValues, ',') + ' * * * ?';
    }
}
