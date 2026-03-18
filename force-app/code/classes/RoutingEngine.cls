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
            return RoutingResult.failure(
                request.recordId,
                'Validation failed: ' + String.join(validationErrors, '; ')
            );
        }

        // ─── Phase 2: Load All Active Configs (0 SOQL) ───────────────────
        List<ConfigBundle> allBundles = ConfigLoader.loadActive();
        if (allBundles.isEmpty()) {
            return RoutingResult.failure(
                request.recordId,
                'No active routing configurations found.'
            );
        }

        // ─── Phase 3: Evaluate Applicable Configs (0 SOQL) ───────────────
        RuleEvaluator.EvaluationResult evalResult =
            RuleEvaluator.evaluate(allBundles, request);

        if (evalResult.applicableBundles.isEmpty()) {
            // Log validation warnings for diagnostics
            for (String warning : evalResult.validationWarnings) {
                System.debug(LoggingLevel.WARN,
                    'RoutingEngine: ' + warning);
            }
            return RoutingResult.noMatch();
        }

        // ─── Phase 4: Pre-fetch User Attributes (0–1 SOQL) ───────────────
        Map<String, Object> userAttributes = new Map<String, Object>();
        if (!evalResult.requiredUserFields.isEmpty()) {
            userAttributes = UserAttributeSelector.getAttributes(
                agentUserId,
                evalResult.requiredUserFields
            );
        }

        // ─── Phase 5: Process Each Applicable Bundle ──────────────────────
        List<AuditLogger.AuditEntry> auditEntries =
            new List<AuditLogger.AuditEntry>();
        Integer successIndex = -1;
        RoutingResult finalResult = null;

        try {
            for (Integer i = 0; i < evalResult.applicableBundles.size(); i++) {
                ConfigBundle bundle = evalResult.applicableBundles[i];

                ProcessOutcome processed = processBundle(
                    bundle, request, agentUserId, entryPoint, userAttributes
                );

                auditEntries.add(processed.auditEntry);

                if (processed.outcome.success) {
                    successIndex = i;
                    finalResult = buildSuccessResult(
                        processed.outcome, agentUserId, entryPoint
                    );
                    break; // First successful assignment wins (pull model)
                }
            }
        } finally {
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
        }

        // ─── Phase 7: Return Result ──────────────────────────────────────
        if (finalResult != null) {
            return finalResult;
        }

        // No bundle produced a successful assignment
        return RoutingResult.noMatch();
    }

    // ─── Inner Value Object ───────────────────────────────────────────────────

    /**
     * @description Pairs an AssignmentOutcome with its AuditEntry for a single bundle.
     *              Keeps the engine loop clean — one method call per bundle, one return type.
     */
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
            System.debug(LoggingLevel.ERROR,
                'RoutingEngine: exception processing config "'
                + bundle.developerName + '": ' + ex.getMessage()
                + '\n' + ex.getStackTraceString());

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
        String entryPoint
    ) {
        RoutingResult rr = RoutingResult.success(
            String.valueOf(outcome.recordId),
            String.valueOf(agentUserId),
            null,                   // routingLogId — set after flush
            outcome.retryCount
        );
        rr.entryPoint = entryPoint;
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
