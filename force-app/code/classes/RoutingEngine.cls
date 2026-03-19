/**
 * @description Stateless orchestrator that coordinates all routing workers and selectors
 *              to execute a single routing transaction. This is the BRAIN of routIQ —
 *              but it contains ZERO business logic, ZERO SOQL, and ZERO DML itself.
 *
 *              Every operation is delegated:
 *                ConfigLoader      → load active configs        (0 SOQL — CMDT cached)
 *                RuleEvaluator     → filter applicable configs  (0 SOQL — in-memory)
 *                UserAttributeSelector → get agent fields       (0–1 SOQL — once for all bundles)
 *                ConditionBinder   → resolve bind variables     (0 SOQL — in-memory)
 *                DynamicQueryBuilder → assemble SOQL            (0 SOQL — string ops)
 *                CandidateSelector → execute candidate query    (1 SOQL per bundle)
 *                AssignmentResolver → lock + assign             (1–N SOQL + 0–1 DML per bundle)
 *                AuditLogger       → insert Routing_Log__c     (1 DML — bulk flush)
 *
 *              Pull model: agent requests → engine finds best candidate → assigns to agent.
 *              First successful assignment wins — engine stops iterating bundles.
 *              All outcomes (success, failure, no-match) are audit-logged.
 *
 *              Governor budget per execution (typical single-config case):
 *                SOQL: 0 (CMDT) + 1 (user attrs) + 1 (candidates) + 1–5 (lock) = 3–7
 *                DML:  1 (assignment update) + 1 (audit flush) = 2
 *
 * @group Orchestrator
 */
public with sharing class RoutingEngine {

    private static final String CLS = 'RoutingEngine';

    // ─── Public API ───────────────────────────────────────────────────────────

    /**
     * @description Executes a complete routing transaction for the given request.
     *
     * @param request     Validated RoutingRequest from the entry layer
     * @param agentUserId Id of the agent requesting work (pull model)
     * @param entryPoint  Integration surface: InvocableMethod, REST, LWC, GlobalAction
     * @return RoutingResult describing the outcome
     */
    public static RoutingResult execute(
        RoutingRequest request,
        Id agentUserId,
        String entryPoint
    ) {
        // ─── Phase 1: Validate Request ────────────────────────────────────
        List<String> validationErrors = request.validate();
        if (!validationErrors.isEmpty()) {
            URE_Logger.warn('Request validation failed: '
                    + String.join(validationErrors, '; '))
                .category(URE_Logger.Category.VALIDATION)
                .inClass(CLS).inMethod('execute')
                .log();
            return RoutingResult.failure(
                request.recordId,
                'Validation failed: ' + String.join(validationErrors, '; ')
            );
        }

        // ── PERF snapshot: after validation ─────────────────────────────
        URE_Logger.perf('Phase 1 complete: request validated')
            .category(URE_Logger.Category.PERFORMANCE)
            .inClass(CLS).inMethod('execute')
            .log();

        // ─── Phase 2: Load All Active Configs (0 SOQL) ───────────────────
        List<ConfigBundle> allBundles = ConfigLoader.loadActive();
        if (allBundles.isEmpty()) {
            URE_Logger.warn('No active routing configurations found')
                .category(URE_Logger.Category.CONFIG)
                .inClass(CLS).inMethod('execute')
                .log();
            return RoutingResult.failure(
                request.recordId,
                'No active routing configurations found.'
            );
        }

        // ── PERF snapshot: after config load ────────────────────────────
        URE_Logger.perf('Phase 2 complete: ' + allBundles.size() + ' configs loaded')
            .category(URE_Logger.Category.PERFORMANCE)
            .inClass(CLS).inMethod('execute')
            .log();

        // ─── Phase 3: Evaluate Applicable Configs (0 SOQL) ───────────────
        RuleEvaluator.EvaluationResult evalResult =
            RuleEvaluator.evaluate(allBundles, request);

        if (evalResult.applicableBundles.isEmpty()) {
            for (String warning : evalResult.validationWarnings) {
                URE_Logger.warn(warning)
                    .category(URE_Logger.Category.VALIDATION)
                    .inClass(CLS).inMethod('execute')
                    .log();
            }
            URE_Logger.info('No applicable configs after evaluation')
                .category(URE_Logger.Category.CONFIG)
                .inClass(CLS).inMethod('execute')
                .log();
            return RoutingResult.noMatch();
        }

        URE_Logger.info('Applicable configs: ' + evalResult.applicableBundles.size()
                + ' | userFields: ' + evalResult.requiredUserFields.size())
            .category(URE_Logger.Category.CONFIG)
            .inClass(CLS).inMethod('execute')
            .log();

        // ── PERF snapshot: after rule evaluation ────────────────────────
        URE_Logger.perf('Phase 3 complete: ' + evalResult.applicableBundles.size()
                + ' applicable bundles')
            .category(URE_Logger.Category.PERFORMANCE)
            .inClass(CLS).inMethod('execute')
            .log();

        // ─── Phase 4: Pre-fetch User Attributes (0–1 SOQL) ───────────────
        Map<String, Object> userAttributes = new Map<String, Object>();
        if (!evalResult.requiredUserFields.isEmpty()) {
            userAttributes = UserAttributeSelector.getAttributes(
                agentUserId,
                evalResult.requiredUserFields
            );
        }

        // ── PERF snapshot: after user attribute query ───────────────────
        URE_Logger.perf('Phase 4 complete: user attributes fetched'
                + ' | fieldCount=' + userAttributes.size())
            .category(URE_Logger.Category.PERFORMANCE)
            .inClass(CLS).inMethod('execute')
            .log();

        // ─── Phase 5: Process Each Applicable Bundle ──────────────────────
        List<AuditLogger.AuditEntry> auditEntries =
            new List<AuditLogger.AuditEntry>();
        Integer successIndex = -1;
        RoutingResult finalResult = null;

        try {
            for (Integer i = 0; i < evalResult.applicableBundles.size(); i++) {
                ConfigBundle bundle = evalResult.applicableBundles[i];

                URE_Logger.info('Processing bundle ' + (i + 1)
                        + '/' + evalResult.applicableBundles.size()
                        + ': "' + bundle.developerName + '"'
                        + ' | object=' + bundle.objectApiName)
                    .category(URE_Logger.Category.ENGINE)
                    .inClass(CLS).inMethod('execute')
                    .forConfig(bundle.developerName)
                    .forObject(bundle.objectApiName)
                    .log();

                ProcessOutcome processed = processBundle(
                    bundle, request, agentUserId, entryPoint, userAttributes
                );

                auditEntries.add(processed.auditEntry);

                if (processed.outcome.success) {
                    successIndex = i;
                    finalResult = buildSuccessResult(
                        processed.outcome, agentUserId, entryPoint,
                        bundle.objectApiName
                    );

                    URE_Logger.info('Assignment succeeded for "'
                            + bundle.developerName + '"'
                            + ' | recordId=' + processed.outcome.recordId
                            + ' | retries=' + processed.outcome.retryCount)
                        .category(URE_Logger.Category.ASSIGNMENT)
                        .inClass(CLS).inMethod('execute')
                        .forConfig(bundle.developerName)
                        .forObject(bundle.objectApiName)
                        .forRecord(processed.outcome.recordId)
                        .log();

                    break; // First successful assignment wins (pull model)
                }
            }
        } finally {
            // ── PERF snapshot: before audit flush ───────────────────────
            URE_Logger.perf('Phase 5 complete: bundle processing done'
                    + ' | auditEntries=' + auditEntries.size())
                .category(URE_Logger.Category.PERFORMANCE)
                .inClass(CLS).inMethod('execute')
                .log();

            // ─── Phase 6: Flush Audit Entries (1 DML) — ALWAYS runs ───────
            List<Id> logIds = AuditLogger.flush(auditEntries);

            // Attach routing log Id to the success result
            if (finalResult != null
                && finalResult.success
                && successIndex >= 0
                && successIndex < logIds.size()
            ) {
                finalResult.routingLogId = (logIds[successIndex] != null)
                    ? String.valueOf(logIds[successIndex])
                    : null;
            }

            // ── PERF snapshot: after audit flush ────────────────────────
            URE_Logger.perf('Phase 6 complete: audit flushed'
                    + ' | logIds=' + logIds.size())
                .category(URE_Logger.Category.PERFORMANCE)
                .inClass(CLS).inMethod('execute')
                .log();
        }

        // ─── Phase 7: Return Result ──────────────────────────────────────
        if (finalResult != null) {
            // Fetch display name for UI (1 SOQL, only on success path)
            if (finalResult.success && String.isNotBlank(finalResult.recordId)) {
                finalResult.recordName = AssignmentSelector.queryRecordName(
                    finalResult.objectApiName,
                    Id.valueOf(finalResult.recordId)
                );
            }
            return finalResult;
        }

        // No bundle produced a successful assignment
        URE_Logger.info('No bundle produced a successful assignment')
            .category(URE_Logger.Category.ENGINE)
            .inClass(CLS).inMethod('execute')
            .log();
        return RoutingResult.noMatch();
    }

    // ─── Inner Value Object ───────────────────────────────────────────────────

    private class ProcessOutcome {
        AssignmentResolver.AssignmentOutcome outcome;
        AuditLogger.AuditEntry auditEntry;
    }

    // ─── Bundle Processing ────────────────────────────────────────────────────

    /**
     * @description Processes a single ConfigBundle through the full pipeline:
     *              bind → build → query → assign → audit entry.
     *
     *              Catches exceptions per-bundle so one bad config does not kill the
     *              entire routing transaction. Failed bundles produce a failure
     *              audit entry and the engine continues to the next bundle.
     *
     * @return ProcessOutcome containing the assignment result and buffered audit entry
     */
    private static ProcessOutcome processBundle(
        ConfigBundle bundle,
        RoutingRequest request,
        Id agentUserId,
        String entryPoint,
        Map<String, Object> userAttributes
    ) {
        ProcessOutcome result = new ProcessOutcome();

        try {
            // ── Resolve bind variables (0 SOQL) ──────────────────────────
            Map<String, Object> bindMap = ConditionBinder.resolveAll(
                bundle.conditions,
                agentUserId,
                userAttributes
            );

            // ── Build SOQL query (0 SOQL) ────────────────────────────────
            QuerySpec spec = DynamicQueryBuilder.build(
                bundle,
                bindMap,
                request.recordId
            );

            // ── Execute candidate query (1 SOQL) ─────────────────────────
            List<SObject> candidates = CandidateSelector.query(spec);

            // ── Resolve assignment (1–N SOQL lock + 0–1 DML update) ──────
            AssignmentResolver.AssignmentOutcome outcome =
                AssignmentResolver.resolve(bundle, candidates, agentUserId);

            // ── Buffer audit entry ───────────────────────────────────────
            result.outcome = outcome;
            result.auditEntry = AuditLogger.createEntry(
                outcome, bundle, agentUserId, entryPoint, spec
            );

        } catch (Exception ex) {
            // ── Per-bundle failure — log and continue ─────────────────────
            URE_Logger.error('Exception processing config "' + bundle.developerName + '"')
                .category(URE_Logger.Category.ENGINE)
                .inClass(CLS).inMethod('processBundle')
                .forConfig(bundle.developerName)
                .forObject(bundle.objectApiName)
                .withException(ex)
                .log();

            result.outcome = buildExceptionOutcome(ex);
            result.auditEntry = AuditLogger.createEntry(
                result.outcome, bundle, agentUserId, entryPoint, null
            );
        }

        return result;
    }

    // ─── Result Builders ──────────────────────────────────────────────────────

    /**
     * @description Builds a RoutingResult from a successful AssignmentOutcome.
     *              The routingLogId is attached later after AuditLogger.flush().
     */
    private static RoutingResult buildSuccessResult(
        AssignmentResolver.AssignmentOutcome outcome,
        Id agentUserId,
        String entryPoint,
        String objectApiName
    ) {
        RoutingResult rr = RoutingResult.success(
            String.valueOf(outcome.recordId),
            String.valueOf(agentUserId),
            null,                   // routingLogId — set after flush
            outcome.retryCount
        );
        rr.entryPoint = entryPoint;
        rr.objectApiName = objectApiName;
        return rr;
    }

    /**
     * @description Builds an AssignmentOutcome from an unexpected exception so
     *              AuditLogger can record it. Delegates to AssignmentResolver's
     *              public outcomeError() factory.
     */
    private static AssignmentResolver.AssignmentOutcome buildExceptionOutcome(
        Exception ex
    ) {
        return AssignmentResolver.outcomeError(
            ex.getTypeName() + ': ' + ex.getMessage()
        );
    }
}
