/**
 * @description Scheduled Apex wrapper around WorkItemReaper.reapAll().
 *              Runs on a configurable interval (default: every 15 minutes
 *              via Scheduled_Job_Config__mdt.Work_Item_Reaper) and sweeps
 *              zombie work items org-wide.
 *
 *              This is the safety net for Agent__c.Current_Load__c accuracy.
 *              Real-time closure should still be wired via Record-Triggered
 *              Flow → WorkItemService.completeWorkItem (invocable), but
 *              this job guarantees eventual consistency even when that
 *              wiring is missing or lagging.
 *
 *              Governor awareness:
 *              - SOQL: 1 (active work items) + N (distinct source objects)
 *              - DML:  1 delete (reaped items) + M (agent load sync per
 *                      affected agent)
 *              - Designed for the same scale as SLAEscalationJob — convert
 *                to Batchable when orgs exceed ~200 active work items.
 *
 * @group Job
 */
public with sharing class WorkItemReaperJob implements Schedulable {

    private static final String CLS = 'WorkItemReaperJob';

    public void execute(SchedulableContext sc) {
        Logger.init('ScheduledJob', null);

        try {
            Integer reaped = WorkItemReaper.reapAll();

            Logger.info('WorkItemReaperJob completed'
                    + ' | reaped=' + reaped)
                .category(Logger.Category.ENGINE)
                .inClass(CLS).inMethod('execute')
                .log();

        } catch (Exception ex) {
            Logger.error('WorkItemReaperJob unhandled exception')
                .category(Logger.Category.ENGINE)
                .inClass(CLS).inMethod('execute')
                .withException(ex)
                .log();
        } finally {
            Logger.flush('Success');
        }
    }
}
