/**
 * @description Scheduled Apex job for SLA escalation processing. Runs on a
 *              configurable interval (default: every 15 minutes via
 *              Scheduled_Job_Config__mdt). Queries all active work items across
 *              escalation-enabled routing configs and delegates threshold
 *              evaluation to EscalationService.
 *
 *              Architecture:
 *              - Implements Schedulable — scheduled/unscheduled from LWC via
 *                ScheduledJobController (no anonymous Apex required)
 *              - Thin orchestrator — all business logic in EscalationService
 *              - Bulkified across SObject types via EscalationSelector
 *
 *              Governor awareness:
 *              - SOQL: 1 (work items) + N (source record queries, N = unique objects)
 *              - DML: 1 (audit logs) + 1 (events) + M (re-route updates, M = escalated records)
 *              - Designed for < 200 active work items per execution. For larger
 *                volumes, convert to Batchable (future enhancement).
 *
 *              Security:
 *              - Runs as the user who scheduled the job.
 *              - All downstream queries/DML use USER_MODE.
 *
 * @group Job
 */
public with sharing class SLAEscalationJob implements Schedulable {

    private static final String CLS = 'SLAEscalationJob';

    // ─── Job name constant used by ScheduledJobController ────────────────
    public static final String JOB_NAME = 'routIQ_SLA_Escalation';

    // =========================================================================
    // Schedulable.execute — entry point
    // =========================================================================

    /**
     * @description Entry point called by the platform on each scheduled tick.
     *              Loads escalation-enabled configs, finds candidates, and
     *              delegates to EscalationService.
     *
     * @param sc The SchedulableContext provided by the platform
     */
    public void execute(SchedulableContext sc) {
        Logger.init('ScheduledJob', null);

        try {
            // ── Load active config bundles (0 SOQL — CMDT cached) ───────
            List<ConfigBundle> allBundles = ConfigLoader.loadActive();

            if (allBundles.isEmpty()) {
                Logger.info('No active routing configs — escalation skipped')
                    .category(Logger.Category.ENGINE)
                    .inClass(CLS).inMethod('execute')
                    .log();
                return;
            }

            // ── Find escalation candidates (1 + N SOQL) ────────────────
            List<EscalationSelector.EscalationCandidate> candidates =
                EscalationSelector.findCandidates(allBundles);

            if (candidates.isEmpty()) {
                Logger.info('No escalation candidates found')
                    .category(Logger.Category.ENGINE)
                    .inClass(CLS).inMethod('execute')
                    .log();
                return;
            }

            // ── Process escalations ─────────────────────────────────────
            EscalationService.EscalationResult result =
                EscalationService.processEscalations(candidates);

            Logger.info('Escalation job completed'
                    + ' | evaluated=' + result.totalEvaluated
                    + ' | escalated=' + result.totalEscalated
                    + ' | skipped=' + result.totalSkipped
                    + ' | errors=' + result.totalErrors)
                .category(Logger.Category.ENGINE)
                .inClass(CLS).inMethod('execute')
                .log();

            if (!result.errors.isEmpty()) {
                for (String err : result.errors) {
                    Logger.warn('Escalation error: ' + err)
                        .category(Logger.Category.ENGINE)
                        .inClass(CLS).inMethod('execute')
                        .log();
                }
            }

        } catch (Exception ex) {
            Logger.error('SLAEscalationJob unhandled exception')
                .category(Logger.Category.ENGINE)
                .inClass(CLS).inMethod('execute')
                .withException(ex)
                .log();
        } finally {
            Logger.flush('Success');
        }
    }
}
