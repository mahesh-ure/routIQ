/**
 * @description Stateless orchestrator that coordinates all routing workers and selectors
 *              to execute a single routing transaction. This is the BRAIN of routIQ —
 *              but it contains ZERO business logic, ZERO SOQL, and ZERO DML itself.
 *
 *              Every operation is delegated:
 *                AgentCapabilitySelector → agent + capability gate (1–2 SOQL — cached)
 *                ConfigLoader      → load active configs          (0 SOQL — CMDT cached)
 *                RuleEvaluator     → filter applicable configs    (0 SOQL — in-memory)
 *                AgentMatcher      → capability type pre-filter   (0 SOQL — cached data)
 *                AssignmentSelector → Allow_Multiple check        (0–1 SOQL per bundle)
 *                ConditionBinder   → resolve bind variables       (0 SOQL — in-memory)
 *                DynamicQueryBuilder → assemble SOQL              (0 SOQL — string ops)
 *                CandidateSelector → execute candidate query      (1 SOQL per bundle)
 *                AgentMatcher      → capability VALUE match       (0 SOQL — cached data)
 *                AssignmentResolver → lock + assign               (1–N SOQL + 1–2 DML)
 *                AuditLogger       → insert Routing_Log__c       (1 DML — bulk flush)
 *
 *              Atomicity model:
 *              • Phases 1–3 are READ-ONLY (0 DML). Fail-fast with no side effects.
 *              • Phase 4 contains DML (assignment). Per-bundle exceptions are caught
 *                and audit-logged — transaction continues for remaining bundles.
 *              • Phase 5 audit flush is in the same transaction. If an unhandled
 *                exception escapes, both assignment and audit DML roll back atomically.
 *              • Allow_Multiple is per-bundle (not global) because each config targets
 *                different objects. SOQL within the same transaction sees dirty reads
 *                from prior bundle DML — this is atomically correct.
 *
 *              Phase order (agent-first):
 *              1. Validate Request           (0 SOQL, 0 DML)
 *              2. Agent & Capability Gate     (1–2 SOQL, 0 DML — fail-fast)
 *              3. Load & Filter Configs       (0 SOQL — CMDT + capability type filter)
 *              4. Process Each Bundle         (per-bundle SOQL + DML)
 *              5. Flush Audit                 (1 DML — always runs via finally)
 *              6. Return Result
 *
 *              Governor budget per execution (typical single-config case):
 *                SOQL: 1 (agents) + 1 (caps) + 0 (CMDT) + 1 (allow_multi)
 *                      + 1 (candidates) + 1 (lock) = 5
 *                DML:  1 (assignment) + 1 (audit flush) = 2
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
        // ═══════════════════════════════════════════════════════════════════
        // ATOMICITY MODEL — Read this before modifying any phase order.
        //
        // Phase 1–3 are READ-ONLY gates (0 DML). They can fail-fast without
        // side effects. Phase 4 contains DML (assignment + audit). Within
        // the bundle loop, each bundle's Allow_Multiple SOQL sees dirty
        // reads from prior bundles' DML — this is correct because
        // Allow_Multiple is a per-config setting (Cases vs Leads).
        //
        // The entire transaction is atomic: if any unhandled exception
        // escapes, ALL DML (assignments + audit) rolls back together.
        // Per-bundle exceptions are caught and audit-logged — the engine
        // continues to the next bundle.
        // ═══════════════════════════════════════════════════════════════════

        // ─── Phase 1: Validate Request (0 SOQL, 0 DML) ─────────────────
        List<String> validationErrors = request.validate();
        if (!validationErrors.isEmpty()) {
            Logger.warn('Request validation failed: '
                    + String.join(validationErrors, '; '))
                .category(Logger.Category.VALIDATION)
                .inClass(CLS).inMethod('execute')
                .log();
            return RoutingResult.failure(
                request.recordId,
                'Validation failed: ' + String.join(validationErrors, '; ')
            );
        }

        // ─── Phase 2: Agent & Capability Gate (1–2 SOQL, 0 DML) ────────
        // Fail-fast, read-only. All data is transaction-cached after first
        // load — subsequent calls within this transaction cost 0 SOQL.
        // Must run BEFORE config loading so we don't waste CMDT reads
        // on an agent who can't receive work.

        Map<Id, Agent__c> agentMap =
            AgentCapabilitySelector.getActiveAgentsByUserId();
        Agent__c currentAgent = agentMap.get(agentUserId);

        if (currentAgent == null) {
            Logger.warn('Agent gate: no active Agent__c record for user '
                    + agentUserId)
                .category(Logger.Category.VALIDATION)
                .inClass(CLS).inMethod('execute')
                .log();
            return RoutingResult.failure(
                request.recordId,
                'No active Agent record found for the current user. '
                + 'An administrator must create an Agent record and assign '
                + 'the required capabilities before routing can proceed.'
            );
        }

        // Capacity gate — uses snapshot load value. Within a single
        // routing request (pull model), this is the pre-transaction value.
        // Agent load is NOT incremented within this transaction, so the
        // snapshot is accurate for all bundles in this execution.
        Decimal currentLoad = currentAgent.Current_Load__c != null
            ? currentAgent.Current_Load__c : 0;
        Decimal maxCapacity = currentAgent.Max_Capacity__c != null
            ? currentAgent.Max_Capacity__c : 0;

        if (maxCapacity > 0 && currentLoad >= maxCapacity) {
            Logger.warn('Agent gate: capacity exceeded | agent='
                    + agentUserId + ' | load=' + currentLoad
                    + ' | max=' + maxCapacity)
                .category(Logger.Category.VALIDATION)
                .inClass(CLS).inMethod('execute')
                .log();
            return RoutingResult.failure(
                request.recordId,
                'Agent has reached maximum capacity ('
                + currentLoad.intValue() + '/' + maxCapacity.intValue()
                + '). Close or reassign existing items before requesting new work.'
            );
        }

        // Pre-load skill data into transaction cache (2-3 SOQL on first call).
        // getCapabilityMap() internally loads assignments + bundle entries.
        // Cached for the remainder of this transaction — AgentMatcher
        // and filterByAgentCapabilities() will read from cache (0 SOQL).
        Map<Id, Map<String, Set<String>>> capabilityMap =
            AgentCapabilitySelector.getCapabilityMap();

        Logger.info('Agent validated | agentId=' + currentAgent.Id
                + ' | user=' + agentUserId
                + ' | load=' + currentLoad + '/' + maxCapacity
                + ' | capabilityTypes='
                + getAgentCapabilityTypeCount(capabilityMap, currentAgent.Id))
            .category(Logger.Category.ENGINE)
            .inClass(CLS).inMethod('execute')
            .withLimits()
            .log();

        // ─── Phase 3: Load & Filter Configs (0 SOQL — CMDT cached) ─────
        List<ConfigBundle> allBundles = ConfigLoader.loadActive();
        if (allBundles.isEmpty()) {
            Logger.warn('No active routing configurations found')
                .category(Logger.Category.CONFIG)
                .inClass(CLS).inMethod('execute')
                .log();
            return RoutingResult.failure(
                request.recordId,
                'No active routing configurations found.'
            );
        }

        RuleEvaluator.EvaluationResult evalResult =
            RuleEvaluator.evaluate(allBundles, request);

        if (evalResult.applicableBundles.isEmpty()) {
            for (String warning : evalResult.validationWarnings) {
                Logger.warn(warning)
                    .category(Logger.Category.VALIDATION)
                    .inClass(CLS).inMethod('execute')
                    .log();
            }
            Logger.info('No applicable configs after evaluation')
                .category(Logger.Category.CONFIG)
                .inClass(CLS).inMethod('execute')
                .log();
            return RoutingResult.noMatch();
        }

        // Capability TYPE pre-filter: exclude bundles where agent lacks
        // mandatory capability TYPES. Pure in-memory check using
        // transaction-cached data (0 SOQL). Saves candidate query SOQL
        // for configs the agent can never satisfy.
        List<ConfigBundle> qualifiedBundles = filterByAgentCapabilities(
            evalResult.applicableBundles, agentUserId
        );

        // ── Consolidated config log ─────────────────────────────────────
        List<String> configNames = new List<String>();
        for (ConfigBundle b : qualifiedBundles) {
            configNames.add(b.developerName);
        }
        Logger.info('Configs loaded | total=' + allBundles.size()
                + ' | applicable=' + evalResult.applicableBundles.size()
                + ' | qualified=' + qualifiedBundles.size()
                + ' | configs=[' + String.join(configNames, ', ') + ']')
            .category(Logger.Category.CONFIG)
            .inClass(CLS).inMethod('execute')
            .log();

        if (qualifiedBundles.isEmpty()) {
            return RoutingResult.failure(
                request.recordId,
                'Agent does not have the required capabilities for any '
                + 'applicable routing configuration.'
            );
        }

        // ─── Phase 4: Process Each Qualified Bundle ─────────────────────
        // DryRun: full matching pipeline executes but processBundle()
        // skips lock + assign DML. Phase 5 skips audit + events entirely.
        Boolean isDryRun = (request.dryRun == true);
        List<AuditLogger.AuditEntry> auditEntries =
            new List<AuditLogger.AuditEntry>();
        List<RoutingConditionTrace> allTraces =
            new List<RoutingConditionTrace>();
        Integer successIndex = -1;
        RoutingResult finalResult = null;

        try {
            for (Integer i = 0; i < qualifiedBundles.size(); i++) {
                ConfigBundle bundle = qualifiedBundles[i];

                Logger.info('Processing bundle ' + (i + 1)
                        + '/' + qualifiedBundles.size()
                        + ': "' + bundle.developerName + '"'
                        + ' | object=' + bundle.objectApiName
                        + (isDryRun ? ' | dryRun=true' : ''))
                    .category(Logger.Category.ENGINE)
                    .inClass(CLS).inMethod('execute')
                    .forConfig(bundle.developerName)
                    .forObject(bundle.objectApiName)
                    .log();

                ProcessOutcome processed = processBundle(
                    bundle, request, agentUserId, entryPoint
                );

                auditEntries.add(processed.auditEntry);
                allTraces.addAll(processed.conditionTraces);

                if (processed.outcome.success) {
                    successIndex = i;
                    finalResult = buildSuccessResult(
                        processed.outcome, agentUserId, entryPoint,
                        bundle.objectApiName
                    );
                    finalResult.conditionTraces = allTraces;
                    finalResult.reasonSummary = buildReasonSummary(
                        processed.outcome, bundle, allTraces, isDryRun
                    );
                    break; // First successful assignment/match wins
                }
            }
        } finally {
            // ─── Phase 5: Audit + Events ────────────────────────────────
            // DryRun: skip ALL side effects — zero DML, zero events.
            if (!isDryRun) {
                // ─── Phase 5a: Flush Audit Entries (1 DML) ──────────────
                List<Id> logIds = AuditLogger.flush(auditEntries);

                if (finalResult != null
                    && finalResult.success
                    && successIndex >= 0
                    && successIndex < logIds.size()
                ) {
                    finalResult.routingLogId = (logIds[successIndex] != null)
                        ? String.valueOf(logIds[successIndex])
                        : null;
                }

                // ─── Phase 5b: Publish Platform Events (1 DML) ─────────
                RoutingEventPublisher.publishFromAudit(
                    auditEntries, request, entryPoint, logIds
                );
            }
        }

        // ─── Phase 6: Return Result ─────────────────────────────────────
        if (finalResult != null) {
            // DryRun: skip recordName query (non-essential, saves 1 SOQL)
            if (!isDryRun
                && finalResult.success
                && String.isNotBlank(finalResult.recordId)
            ) {
                finalResult.recordName = AssignmentSelector.queryRecordName(
                    finalResult.objectApiName,
                    Id.valueOf(finalResult.recordId)
                );
            }
            return finalResult;
        }

        // No bundle produced a match — build no-match result with traces
        Logger.info('No bundle produced a successful assignment'
                + (isDryRun ? ' (dryRun)' : ''))
            .category(Logger.Category.ENGINE)
            .inClass(CLS).inMethod('execute')
            .log();

        RoutingResult noMatchResult = RoutingResult.noMatch();
        noMatchResult.conditionTraces = allTraces;
        noMatchResult.reasonSummary = 'No matching candidates found across '
            + qualifiedBundles.size() + ' qualified configuration(s).'
            + (isDryRun ? ' [Dry Run]' : '');
        return noMatchResult;
    }

    // ─── Inner Value Object ───────────────────────────────────────────────────

    private class ProcessOutcome {
        AssignmentResolver.AssignmentOutcome outcome;
        AuditLogger.AuditEntry auditEntry;
        List<RoutingConditionTrace> conditionTraces;

        private ProcessOutcome() {
            this.conditionTraces = new List<RoutingConditionTrace>();
        }
    }

    // ─── Bundle Processing ────────────────────────────────────────────────────

    /**
     * @description Processes a single ConfigBundle through the atomicity-aware pipeline:
     *
     *              1. Allow_Multiple gate (1 SOQL — BEFORE candidate query to save SOQL)
     *              2. Bind → Build → Query candidates (0 + 0 + 1 SOQL)
     *              3. Agent capability VALUE match (0 SOQL — cached)
     *              4. Lock + Assign (1–N SOQL + 1–2 DML)
     *
     *              Atomicity notes:
     *              • Allow_Multiple uses SOQL that sees dirty reads from prior bundle
     *                DML within the same transaction. This is CORRECT — an agent who
     *                was just assigned a Case in Bundle 1 should be blocked from
     *                receiving another Case in Bundle 2 (if Allow_Multiple=false).
     *              • Each config targets different objects, so Allow_Multiple is
     *                inherently per-bundle (Cases vs Leads are independent).
     *              • CapabilityMismatchException is caught and converted to an
     *                audit-loggable outcome — the engine continues to the next bundle.
     *
     * @return ProcessOutcome containing the assignment result and buffered audit entry
     */
    private static ProcessOutcome processBundle(
        ConfigBundle bundle,
        RoutingRequest request,
        Id agentUserId,
        String entryPoint
    ) {
        ProcessOutcome result = new ProcessOutcome();
        Boolean isDryRun = (request.dryRun == true);

        try {
            // ── Allow_Multiple gate (1 SOQL) — BEFORE candidate query ────
            // DryRun still evaluates this gate to accurately simulate behavior.
            if (!bundle.allowMultiple) {
                List<SObject> existing = AssignmentSelector.queryOwnedRecords(
                    bundle.objectApiName,
                    bundle.ownerFieldApiName,
                    agentUserId
                );
                if (!existing.isEmpty()) {
                    Logger.info('Agent already assigned (Allow_Multiple=false)'
                            + ' | config=' + bundle.developerName
                            + ' | agent=' + agentUserId
                            + (isDryRun ? ' | dryRun=true' : ''))
                        .category(Logger.Category.ASSIGNMENT)
                        .inClass(CLS).inMethod('processBundle')
                        .forConfig(bundle.developerName)
                        .forObject(bundle.objectApiName)
                        .log();
                    result.outcome = AssignmentResolver.outcomeAlreadyAssigned();
                    result.auditEntry = AuditLogger.createEntry(
                        result.outcome, bundle, agentUserId, entryPoint, null
                    );
                    return result;
                }
            }

            // ── Resolve bind variables (0 SOQL) — STATIC only ───────────
            Map<String, Object> bindMap = ConditionBinder.resolveAll(
                bundle.conditions
            );

            // ── Build SOQL query (0 SOQL) ────────────────────────────────
            QuerySpec spec = DynamicQueryBuilder.build(
                bundle,
                bindMap,
                request.recordId
            );

            // ── Execute candidate query (1 SOQL) ─────────────────────────
            List<SObject> candidates = CandidateSelector.query(spec);

            // ── Condition Traces (Layer 2) — evaluate conditions against top candidate ──
            if (!candidates.isEmpty()) {
                result.conditionTraces = buildConditionTraces(
                    bundle.conditions, candidates[0]
                );
            } else {
                result.conditionTraces = buildConditionTracesNoRecord(
                    bundle.conditions
                );
            }

            // ── Agent capability VALUE match (0 SOQL — cached data) ──────
            // Layer 4: AgentMatcher now returns skill traces on MatchResult.
            // Append them to conditionTraces for unified trace output.
            if (!candidates.isEmpty() && !bundle.matchConditions.isEmpty()) {
                SObject topCandidate = candidates[0];
                AgentMatcher.MatchResult matchResult = AgentMatcher.evaluate(
                    topCandidate,
                    bundle.matchConditions,
                    agentUserId,
                    bundle.developerName
                );

                // Layer 4: Append skill match traces
                if (matchResult.skillTraces != null) {
                    result.conditionTraces.addAll(matchResult.skillTraces);
                }

                if (!matchResult.matched) {
                    result.outcome = AssignmentResolver.outcomeCapabilityMismatch(
                        'Agent does not match required capabilities.'
                    );
                    result.auditEntry = AuditLogger.createEntry(
                        result.outcome, bundle, agentUserId, entryPoint, spec
                    );
                    return result;
                }
            }

            // ── DryRun: skip Lock + Assign — produce simulated outcome ──
            if (isDryRun) {
                Id topRecordId = (!candidates.isEmpty())
                    ? candidates[0].Id
                    : null;
                result.outcome = (topRecordId != null)
                    ? AssignmentResolver.outcomeDryRun(topRecordId, candidates.size())
                    : AssignmentResolver.outcomeError('No matching candidates found (dry run).');
                result.auditEntry = AuditLogger.createEntry(
                    result.outcome, bundle, agentUserId, entryPoint, spec
                );
                return result;
            }

            // ── Lock + Assign (1–N SOQL + 1–2 DML) — live mode only ─────
            AssignmentResolver.AssignmentOutcome outcome =
                AssignmentResolver.resolve(bundle, candidates, agentUserId);

            result.outcome = outcome;
            result.auditEntry = AuditLogger.createEntry(
                outcome, bundle, agentUserId, entryPoint, spec
            );

        } catch (CapabilityMismatchException cmEx) {
            Logger.warn('Capability/capacity gate failed for config "'
                    + bundle.developerName + '" | ' + cmEx.getMessage())
                .category(Logger.Category.ENGINE)
                .inClass(CLS).inMethod('processBundle')
                .forConfig(bundle.developerName)
                .forObject(bundle.objectApiName)
                .log();

            String status = cmEx.getMessage().contains('maximum open items')
                ? 'Capacity_Exceeded'
                : 'Capability_Mismatch';

            if (status == 'Capacity_Exceeded') {
                result.outcome = AssignmentResolver.outcomeCapacityExceeded(
                    cmEx.getMessage()
                );
            } else {
                result.outcome = AssignmentResolver.outcomeCapabilityMismatch(
                    cmEx.getMessage()
                );
            }
            result.auditEntry = AuditLogger.createEntry(
                result.outcome, bundle, agentUserId, entryPoint, null
            );

        } catch (Exception ex) {
            Logger.error('Exception processing config "' + bundle.developerName + '"')
                .category(Logger.Category.ENGINE)
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

    // ─── Capability Pre-filter ─────────────────────────────────────────────────

    /**
     * @description Filters applicable bundles to only those where the agent has
     *              the required mandatory capability TYPES. Pure in-memory check
     *              using transaction-cached capability data (0 SOQL).
     *
     *              TYPE-level filter: "does agent have a Province capability?"
     *              VALUE-level filter: "does agent have Ontario?" — happens later
     *              in AgentMatcher.evaluate() after candidates are queried.
     *
     *              Bundles with no matchConditions pass through (agent auto-qualifies).
     *              This prevents wasting SOQL on candidate queries for configs the
     *              agent can never satisfy.
     *
     * @param bundles      Applicable bundles from RuleEvaluator
     * @param agentUserId  The requesting agent's User Id
     * @return Filtered list of bundles where the agent has required capability types
     */
    private static List<ConfigBundle> filterByAgentCapabilities(
        List<ConfigBundle> bundles,
        Id agentUserId
    ) {
        List<ConfigBundle> qualified = new List<ConfigBundle>();
        for (ConfigBundle bundle : bundles) {
            if (AgentMatcher.hasRequiredCapabilityTypes(
                bundle.matchConditions, agentUserId
            )) {
                qualified.add(bundle);
            }
        }
        return qualified;
    }

    /**
     * @description Returns the count of distinct capability types the agent has.
     *              Used for consolidated logging — shows agent's capability breadth.
     */
    private static Integer getAgentCapabilityTypeCount(
        Map<Id, Map<String, Set<String>>> capabilityMap,
        Id agentId
    ) {
        Map<String, Set<String>> agentCaps = capabilityMap.get(agentId);
        return (agentCaps != null) ? agentCaps.size() : 0;
    }

    // ─── Result Builders ──────────────────────────────────────────────────────

    /**
     * @description Builds a RoutingResult from a successful AssignmentOutcome.
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
     * @description Builds an AssignmentOutcome from an unexpected exception.
     */
    private static AssignmentResolver.AssignmentOutcome buildExceptionOutcome(
        Exception ex
    ) {
        return AssignmentResolver.outcomeError(
            ex.getTypeName() + ': ' + ex.getMessage()
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LAYER 2 — Condition Traces + Reason Summary
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @description Builds condition traces by evaluating each Routing_Condition__mdt
     *              against the top candidate record. Each trace captures:
     *              • The field, operator, and expected values from CMDT
     *              • The actual value found on the record
     *              • Whether the condition passed (record matched the query WHERE clause)
     *
     *              Because conditions are evaluated in SOQL (not in-memory), the
     *              candidate already satisfies all conditions. Traces here are
     *              confirmatory — they show callers WHAT was tested and what the
     *              record's actual values were. Useful for dryRun simulation display.
     *
     * @param conditions  Sorted conditions from ConfigBundle
     * @param topCandidate The first candidate record returned by the query
     * @return List of RoutingConditionTrace, one per condition
     */
    private static List<RoutingConditionTrace> buildConditionTraces(
        List<Routing_Condition__mdt> conditions,
        SObject topCandidate
    ) {
        List<RoutingConditionTrace> traces = new List<RoutingConditionTrace>();

        if (conditions == null || conditions.isEmpty()) {
            return traces;
        }

        for (Routing_Condition__mdt cond : conditions) {
            Object actualObj = safeGetField(topCandidate, cond.Field_API_Name__c);
            String actualValue = (actualObj != null)
                ? String.valueOf(actualObj)
                : '';

            // The candidate passed the SOQL WHERE clause, so all conditions
            // are satisfied. Trace records confirm this for display.
            // Layer 3: Include condition group, value type, and sort order metadata.
            traces.add(RoutingConditionTrace.createWithMetadata(
                cond.Field_API_Name__c,
                cond.Operator__c,
                cond.Values__c,
                actualValue,
                true,
                cond.Condition_Group__c,
                cond.Value_Type__c,
                cond.Sort_Order__c
            ));
        }

        return traces;
    }

    /**
     * @description Builds condition traces when no candidates were returned.
     *              All conditions are marked as passed=false since there is no
     *              record to evaluate against.
     */
    private static List<RoutingConditionTrace> buildConditionTracesNoRecord(
        List<Routing_Condition__mdt> conditions
    ) {
        List<RoutingConditionTrace> traces = new List<RoutingConditionTrace>();

        if (conditions == null || conditions.isEmpty()) {
            return traces;
        }

        for (Routing_Condition__mdt cond : conditions) {
            // Layer 3: Include condition group, value type, and sort order metadata.
            traces.add(RoutingConditionTrace.createWithMetadata(
                cond.Field_API_Name__c,
                cond.Operator__c,
                cond.Values__c,
                '',     // No record -- no actual value
                false,  // No record matched
                cond.Condition_Group__c,
                cond.Value_Type__c,
                cond.Sort_Order__c
            ));
        }

        return traces;
    }

    /**
     * @description Safely reads a field value from an SObject without throwing
     *              SObjectException on missing fields.
     */
    private static Object safeGetField(SObject record, String fieldApiName) {
        if (record == null || String.isBlank(fieldApiName)) {
            return null;
        }
        try {
            return record.get(fieldApiName);
        } catch (SObjectException ex) {
            return null;
        }
    }

    /**
     * @description Builds a human-readable reason summary for the routing outcome.
     *              Consumed by Setup Wizard simulate step and Supervisor Dashboard.
     *
     * @param outcome  The assignment result
     * @param bundle   The config that produced the outcome
     * @param traces   Condition traces for the evaluation
     * @param isDryRun Whether this was a simulation
     * @return One-line summary describing the routing decision
     */
    private static String buildReasonSummary(
        AssignmentResolver.AssignmentOutcome outcome,
        ConfigBundle bundle,
        List<RoutingConditionTrace> traces,
        Boolean isDryRun
    ) {
        Integer passedCount = 0;
        for (RoutingConditionTrace t : traces) {
            if (t.passed) {
                passedCount++;
            }
        }
        String condSummary = passedCount + ' of ' + traces.size()
            + ' condition(s) matched';

        String prefix = isDryRun ? '[Dry Run] ' : '';

        if (outcome.success) {
            return prefix + 'Assigned via "' + bundle.developerName + '" — '
                + condSummary
                + ', ' + outcome.candidateCount + ' candidate(s) found'
                + (outcome.retryCount > 0
                    ? ', ' + outcome.retryCount + ' lock retry(ies)'
                    : '')
                + '.';
        }

        // Failure summaries by status
        String status = outcome.status;
        if (status == 'Dry_Run') {
            return prefix + 'Would assign via "' + bundle.developerName + '" — '
                + condSummary
                + ', ' + outcome.candidateCount + ' candidate(s) found.';
        }

        return prefix + 'No assignment via "' + bundle.developerName + '" — '
            + outcome.errorMessage;
    }
}
