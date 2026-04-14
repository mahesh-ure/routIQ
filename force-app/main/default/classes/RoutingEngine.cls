/**
 * @description Stateless orchestrator — delegates all SOQL/DML to workers (AgentCapabilitySelector,
 *              ConfigLoader, RuleEvaluator, AgentMatcher, CandidateSelector, AssignmentResolver, AuditLogger).
 *              Phases: 1-Validate, 2-AgentGate, 3-LoadConfigs, 4-ProcessBundles(DML), 5-AuditFlush, 6-Return.
 *              Phases 1-3 are read-only fail-fast; Phase 4+ DML rolls back atomically on unhandled exceptions.
 *              Typical governor budget: ~5 SOQL + 2 DML per single-config execution.
 * @group Orchestrator
 */
public with sharing class RoutingEngine {

    private static final String CLS = 'RoutingEngine';

    /** @description Executes a complete routing transaction for the given request. */
    public static RoutingResult execute(
        RoutingRequest request,
        Id agentUserId,
        String entryPoint
    ) {
        // Atomicity: Phases 1-3 read-only (fail-fast, 0 DML). Phase 4+ DML rolls back atomically on unhandled exception.
        // Per-bundle exceptions are caught and audit-logged — engine continues to next bundle.

        // Analytics: capture request receipt time for Assignment_Duration_Ms__c computation.
        Long requestStartMs = System.currentTimeMillis();

        // Phase 1: Validate Request (0 SOQL, 0 DML)
        List<String> validationErrors = request.validate();
        if (!validationErrors.isEmpty()) {
            Logger.warn('Request validation failed: '
                    + String.join(validationErrors, '; '))
                .category(Logger.Category.VALIDATION)
                .inClass(CLS).inMethod('execute')
                .log();
            return RoutingResult.failure(
                request.recordId,
                String.format(System.Label.URE_ROUTING_VALIDATION_FAILED,
                    new List<Object>{String.join(validationErrors, '; ')})
            );
        }

        // Phase 2: Agent & Capability Gate (fail-fast, read-only, transaction-cached after first load)
        Map<Id, Agent__c> agentMap = AgentCapabilitySelector.getActiveAgentsByUserId();
        Agent__c currentAgent = agentMap.get(agentUserId);

        if (currentAgent == null) {
            Logger.warn('Agent gate: no active Agent__c record for user '
                    + agentUserId)
                .category(Logger.Category.VALIDATION)
                .inClass(CLS).inMethod('execute')
                .log();
            return RoutingResult.failure(
                request.recordId,
                System.Label.URE_ROUTING_NO_AGENT_ERROR
            );
        }

        // Capacity gate — snapshot load value, accurate for all bundles in this execution
        Decimal currentLoad = currentAgent.Current_Load__c != null ? currentAgent.Current_Load__c : 0;
        Decimal maxCapacity = currentAgent.Max_Capacity__c != null ? currentAgent.Max_Capacity__c : 0;

        if (maxCapacity > 0 && currentLoad >= maxCapacity) {
            Logger.warn('Agent gate: capacity exceeded | agent='
                    + agentUserId + ' | load=' + currentLoad
                    + ' | max=' + maxCapacity)
                .category(Logger.Category.VALIDATION)
                .inClass(CLS).inMethod('execute')
                .log();
            return RoutingResult.failure(
                request.recordId,
                String.format(System.Label.URE_ROUTING_CAPACITY_FULL_ERROR,
                    new List<Object>{currentLoad.intValue(), maxCapacity.intValue()})
            );
        }

        // Availability gate — Away/Offline agents excluded (0 extra SOQL, field already queried)
        String availStatus = (String) currentAgent.get('Availability_Status__c');
        if (availStatus == 'Away' || availStatus == 'Offline') {
            Logger.warn('Agent gate: availability excluded | agent='
                    + agentUserId + ' | status=' + availStatus)
                .category(Logger.Category.VALIDATION)
                .inClass(CLS).inMethod('execute')
                .log();
            return RoutingResult.failure(
                request.recordId,
                String.format(System.Label.URE_ROUTING_AVAILABILITY_ERROR,
                    new List<Object>{availStatus})
            );
        }

        // Override Agent shortcut — direct assignment bypassing candidate ranking (Supervisor Dashboard)
        if (request.overrideAgentId != null) {
            return executeOverride(request, agentUserId, entryPoint);
        }

        // Pre-load skill data into transaction cache (2-3 SOQL on first call, 0 on subsequent)
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

        // Phase 3: Load & Filter Configs (0 SOQL — CMDT cached)
        List<ConfigBundle> allBundles = ConfigLoader.loadActive();
        if (allBundles.isEmpty()) {
            Logger.warn('No active routing configurations found')
                .category(Logger.Category.CONFIG)
                .inClass(CLS).inMethod('execute')
                .log();
            return RoutingResult.failure(
                request.recordId,
                System.Label.URE_ROUTING_NO_CONFIG_ERROR
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

        // Capability TYPE pre-filter: exclude bundles agent can never satisfy (0 SOQL, in-memory)
        List<ConfigBundle> qualifiedBundles = filterByAgentCapabilities(
            evalResult.applicableBundles, agentUserId
        );

        // Consolidated config log
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
                System.Label.URE_ROUTING_NO_CAPABILITY_ERROR
            );
        }

        // Phase 4: Process Each Qualified Bundle (DryRun skips DML in processBundle; Phase 5 skips audit)
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
                        + ' | maxCapacity='
                        + (bundle.maxCapacity != null
                            ? String.valueOf(bundle.maxCapacity)
                            : 'null')
                        + ' | ignoreCapacity=' + bundle.ignoreCapacity
                        + ' | candidateLimit=' + bundle.candidateLimit
                        + (isDryRun ? ' | dryRun=true' : ''))
                    .category(Logger.Category.ENGINE)
                    .inClass(CLS).inMethod('execute')
                    .forConfig(bundle.developerName)
                    .forObject(bundle.objectApiName)
                    .log();

                ProcessOutcome processed = processBundle(
                    bundle, request, agentUserId, entryPoint, availStatus
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
                        processed.outcome, bundle, allTraces, isDryRun,
                        currentAgent
                    );
                    break; // First successful assignment/match wins
                }
            }
        } finally {
            // Phase 5: Audit + Events (DryRun skips all side effects)
            if (!isDryRun) {
                // Phase 5a: Enrich audit entries with analytics (0 SOQL — uses cached agent name)
                String agentDisplayName = (currentAgent.getSObject('User__r') != null)
                    ? (String) currentAgent.getSObject('User__r').get('Name')
                    : null;
                AuditLogger.enrichWithAnalytics(
                    auditEntries, qualifiedBundles, requestStartMs, agentDisplayName
                );

                // Phase 5b: Flush Audit Entries (1 DML)
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

                // Phase 5c: Publish Platform Events (1 DML)
                RoutingEventPublisher.publishFromAudit(
                    auditEntries, request, entryPoint, logIds
                );
            }
        }

        // Phase 6: Return Result
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
        noMatchResult.reasonSummary = String.format(
            System.Label.URE_ROUTING_NO_MATCH_SUMMARY,
            new List<Object>{qualifiedBundles.size(), (isDryRun ? ' [Dry Run]' : '')}
        );
        return noMatchResult;
    }

    private class ProcessOutcome {
        AssignmentResolver.AssignmentOutcome outcome;
        AuditLogger.AuditEntry auditEntry;
        List<RoutingConditionTrace> conditionTraces;

        private ProcessOutcome() {
            this.conditionTraces = new List<RoutingConditionTrace>();
        }
    }

    /**
     * @description Processes a single ConfigBundle: Open Work Item Gate → Bind → Query
     *              → Capability match → Lock + Assign. CapabilityMismatchExceptions are
     *              caught and audit-logged so the engine continues to the next bundle.
     *              SOQL within the same transaction sees dirty reads from prior bundle DML
     *              (correct — capacity is per-config, Cases vs Leads are independent).
     */
    private static ProcessOutcome processBundle(
        ConfigBundle bundle,
        RoutingRequest request,
        Id agentUserId,
        String entryPoint,
        String availStatus
    ) {
        ProcessOutcome result = new ProcessOutcome();
        Boolean isDryRun = (request.dryRun == true);

        try {
            // Busy agent gate: exclude Busy agents when config disallows (Away/Offline blocked in Phase 2)
            if (!bundle.includeBusyAgents && availStatus == 'Busy') {
                Logger.info('Agent excluded (Busy, Include_Busy_Agents=false)'
                        + ' | config=' + bundle.developerName
                        + ' | agent=' + agentUserId)
                    .category(Logger.Category.ENGINE)
                    .inClass(CLS).inMethod('processBundle')
                    .forConfig(bundle.developerName)
                    .forObject(bundle.objectApiName)
                    .log();
                result.outcome = AssignmentResolver.outcomeError(
                    System.Label.URE_ROUTING_BUSY_EXCLUDED
                );
                result.auditEntry = AuditLogger.createEntry(
                    result.outcome, bundle, agentUserId, entryPoint, null
                );
                return result;
            }

            // Open Work Item Gate (0-1 SOQL). Ignore_Capacity=true skips gate entirely.
            // Closed statuses excluded so completed records never block new assignments.
            Integer effectiveCap;
            if (bundle.ignoreCapacity) {
                effectiveCap = null; // unlimited — skip the gate
            } else if (bundle.maxCapacity != null) {
                effectiveCap = bundle.maxCapacity;
            } else {
                effectiveCap = 1;    // conservative legacy default
            }

            if (effectiveCap != null) {
                List<SObject> existing = AssignmentSelector.queryOwnedRecords(
                    bundle.objectApiName,
                    bundle.ownerFieldApiName,
                    agentUserId,
                    bundle.closedStatusFieldApiName,
                    bundle.closedStatusValues,
                    effectiveCap
                );
                if (existing.size() >= effectiveCap) {
                    Logger.info('Agent at per-config capacity'
                            + ' | config=' + bundle.developerName
                            + ' | agent=' + agentUserId
                            + ' | open=' + existing.size()
                            + ' | cap=' + effectiveCap
                            + ' | maxCapacity='
                            + (bundle.maxCapacity != null
                                ? String.valueOf(bundle.maxCapacity)
                                : 'null')
                            + ' | ignoreCapacity=' + bundle.ignoreCapacity
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

            // Resolve bind variables → Build SOQL → Execute candidate query
            Map<String, Object> bindMap = ConditionBinder.resolveAll(bundle.conditions);
            QuerySpec spec = DynamicQueryBuilder.build(bundle, bindMap, request.recordId);
            List<SObject> candidates = CandidateSelector.query(spec);

            // Build condition traces for simulation/audit display
            if (!candidates.isEmpty()) {
                result.conditionTraces = buildConditionTraces(
                    bundle.conditions, candidates[0]
                );
            } else {
                result.conditionTraces = buildConditionTracesNoRecord(
                    bundle.conditions
                );
            }

            // Agent capability VALUE match (0 SOQL — cached). Append skill traces to condition traces.
            if (!candidates.isEmpty() && !bundle.matchConditions.isEmpty()) {
                SObject topCandidate = candidates[0];
                AgentMatcher.MatchResult matchResult = AgentMatcher.evaluate(
                    topCandidate,
                    bundle.matchConditions,
                    agentUserId,
                    bundle.developerName
                );

                if (matchResult.skillTraces != null) {
                    result.conditionTraces.addAll(matchResult.skillTraces);
                }

                if (!matchResult.matched) {
                    result.outcome = AssignmentResolver.outcomeCapabilityMismatch(
                        System.Label.URE_ROUTING_CAPABILITY_MISMATCH
                    );
                    result.auditEntry = AuditLogger.createEntry(
                        result.outcome, bundle, agentUserId, entryPoint, spec
                    );
                    return result;
                }
            }

            // DryRun: skip Lock + Assign, produce simulated outcome
            if (isDryRun) {
                Id topRecordId = (!candidates.isEmpty())
                    ? candidates[0].Id
                    : null;
                result.outcome = (topRecordId != null)
                    ? AssignmentResolver.outcomeDryRun(topRecordId, candidates.size())
                    : AssignmentResolver.outcomeError(System.Label.URE_ROUTING_NO_MATCH_DRYRUN);
                result.auditEntry = AuditLogger.createEntry(
                    result.outcome, bundle, agentUserId, entryPoint, spec
                );
                return result;
            }

            // Lock + Assign (1-N SOQL + 1-2 DML) — live mode only
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

    /**
     * @description Filters bundles to those where the agent has required mandatory capability
     *              TYPES (not values). In-memory check using cached data (0 SOQL). Bundles
     *              with no matchConditions pass through. Prevents wasting SOQL on impossible configs.
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

    /** @description Returns the count of distinct capability types the agent has (for logging). */
    private static Integer getAgentCapabilityTypeCount(
        Map<Id, Map<String, Set<String>>> capabilityMap,
        Id agentId
    ) {
        Map<String, Set<String>> agentCaps = capabilityMap.get(agentId);
        return (agentCaps != null) ? agentCaps.size() : 0;
    }

    /** @description Builds a RoutingResult from a successful AssignmentOutcome. */
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

    /** @description Builds an AssignmentOutcome from an unexpected exception. */
    private static AssignmentResolver.AssignmentOutcome buildExceptionOutcome(
        Exception ex
    ) {
        return AssignmentResolver.outcomeError(
            ex.getTypeName() + ': ' + ex.getMessage()
        );
    }

    /**
     * @description Builds confirmatory condition traces against the top candidate record.
     *              Candidates already satisfy SOQL WHERE — traces show what was tested
     *              and actual field values for dryRun simulation display.
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

            // Candidate passed SOQL WHERE — trace is confirmatory
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

    /** @description Builds condition traces when no candidates returned (all marked passed=false). */
    private static List<RoutingConditionTrace> buildConditionTracesNoRecord(
        List<Routing_Condition__mdt> conditions
    ) {
        List<RoutingConditionTrace> traces = new List<RoutingConditionTrace>();

        if (conditions == null || conditions.isEmpty()) {
            return traces;
        }

        for (Routing_Condition__mdt cond : conditions) {
            // No record matched — trace with empty actual value
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

    /** @description Safely reads a field from an SObject; returns null on missing fields. */
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
     *              Used by Setup Wizard simulation step and Supervisor Dashboard.
     */
    private static String buildReasonSummary(
        AssignmentResolver.AssignmentOutcome outcome,
        ConfigBundle bundle,
        List<RoutingConditionTrace> traces,
        Boolean isDryRun,
        Agent__c agent
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

        // Agent context: name (User__c) + capacity snapshot
        Decimal load = (agent.Current_Load__c != null) ? agent.Current_Load__c : 0;
        Decimal cap = (agent.Max_Capacity__c != null) ? agent.Max_Capacity__c : 0;
        String agentCtx = ' | agent=' + agent.User__c
            + ' capacity=' + load.intValue() + '/' + cap.intValue();

        if (outcome.success) {
            return prefix + 'Assigned via "' + bundle.developerName + '" — '
                + condSummary
                + ', ' + outcome.candidateCount + ' candidate(s) found'
                + (outcome.retryCount > 0
                    ? ', ' + outcome.retryCount + ' lock retry(ies)'
                    : '')
                + agentCtx + '.';
        }

        String status = outcome.status;
        if (status == 'Dry_Run') {
            return prefix + 'Would assign via "' + bundle.developerName + '" — '
                + condSummary
                + ', ' + outcome.candidateCount + ' candidate(s) found'
                + agentCtx + '.';
        }

        return prefix + 'No assignment via "' + bundle.developerName + '" — '
            + outcome.errorMessage + agentCtx + '.';
    }

    /**
     * @description Direct assignment to a specific agent, bypassing candidate ranking
     *              and capability matching (Supervisor Dashboard manual reassign).
     *              Validates agent exists and is not Offline. Still creates audit + events.
     */
    private static RoutingResult executeOverride(
        RoutingRequest request,
        Id agentUserId,
        String entryPoint
    ) {
        Boolean isDryRun = (request.dryRun == true);

        // ── Validate recordId is present ────────────────────────────────
        if (request.recordId == null) {
            return RoutingResult.failure(
                null,
                'Override assignment requires a recordId.'
            );
        }

        // ── Find override agent by Agent__c Id ─────────────────────────
        // The cached agent map is keyed by User__c. Iterate to find by Id.
        Map<Id, Agent__c> agentMap =
            AgentCapabilitySelector.getActiveAgentsByUserId();
        Agent__c overrideAgent = null;

        for (Agent__c agent : agentMap.values()) {
            if (agent.Id == request.overrideAgentId) {
                overrideAgent = agent;
                break;
            }
        }

        if (overrideAgent == null) {
            Logger.warn('Override failed: no active Agent__c with Id='
                    + request.overrideAgentId)
                .category(Logger.Category.VALIDATION)
                .inClass(CLS).inMethod('executeOverride')
                .log();
            return RoutingResult.failure(
                String.valueOf(request.recordId),
                'Override agent not found or is inactive (Id='
                + request.overrideAgentId + ').'
            );
        }

        // ── Validate not Offline ────────────────────────────────────────
        String overrideStatus = (String) overrideAgent.get('Availability_Status__c');
        if (overrideStatus == 'Offline') {
            Logger.warn('Override failed: agent is Offline | agentId='
                    + overrideAgent.Id)
                .category(Logger.Category.VALIDATION)
                .inClass(CLS).inMethod('executeOverride')
                .log();
            return RoutingResult.failure(
                String.valueOf(request.recordId),
                'Override agent is Offline and cannot receive assignments.'
            );
        }

        // ── Load config bundle for audit context ────────────────────────
        // If configDeveloperName is specified, use it. Otherwise pick the
        // first applicable bundle for the record's object type.
        List<ConfigBundle> allBundles = ConfigLoader.loadActive();
        ConfigBundle matchedBundle = null;

        if (String.isNotBlank(request.configDeveloperName)) {
            for (ConfigBundle b : allBundles) {
                if (b.developerName == request.configDeveloperName) {
                    matchedBundle = b;
                    break;
                }
            }
        }

        // Fallback: use the first active bundle (for audit context only)
        if (matchedBundle == null && !allBundles.isEmpty()) {
            matchedBundle = allBundles[0];
        }

        // ── DryRun: return simulated outcome, skip all DML ─────────────
        if (isDryRun) {
            RoutingResult dryResult = RoutingResult.success(
                String.valueOf(request.recordId),
                String.valueOf(overrideAgent.User__c),
                null,
                0
            );
            dryResult.entryPoint = entryPoint;
            dryResult.reasonSummary = '[Dry Run] Would override-assign to agent '
                + overrideAgent.Id + '.';
            return dryResult;
        }

        // ── Direct assignment DML ───────────────────────────────────────
        // Query the record with FOR UPDATE lock, set owner, save.
        String objectApiName = (matchedBundle != null)
            ? matchedBundle.objectApiName
            : Id.valueOf(request.recordId).getSObjectType().getDescribe().getName();
        String ownerField = (matchedBundle != null)
            ? matchedBundle.ownerFieldApiName
            : 'OwnerId';

        try {
            String lockSoql = 'SELECT Id, ' + ownerField
                + ' FROM ' + objectApiName
                + ' WHERE Id = :recordId FOR UPDATE';
            Id recId = Id.valueOf(request.recordId);
            Map<String, Object> binds = new Map<String, Object>{
                'recordId' => recId
            };
            List<SObject> locked = Database.queryWithBinds(
                lockSoql, binds, AccessLevel.USER_MODE
            );

            if (locked.isEmpty()) {
                return RoutingResult.failure(
                    String.valueOf(request.recordId),
                    'Record not found or inaccessible (Id='
                    + request.recordId + ').'
                );
            }

            SObject record = locked[0];
            record.put(ownerField, overrideAgent.User__c);

            Database.SaveResult sr = Database.update(
                record, false, AccessLevel.USER_MODE
            );

            if (!sr.isSuccess()) {
                String errors = '';
                for (Database.Error err : sr.getErrors()) {
                    errors += err.getMessage() + '; ';
                }
                Logger.error('Override DML failed | recordId='
                        + request.recordId + ' | errors=' + errors)
                    .category(Logger.Category.ASSIGNMENT)
                    .inClass(CLS).inMethod('executeOverride')
                    .log();
                return RoutingResult.failure(
                    String.valueOf(request.recordId),
                    'Override assignment failed: ' + errors
                );
            }

            // ── Audit + Platform Event ──────────────────────────────────
            // Use outcomeDryRun factory (success=true). Status shows as
            // Dry_Run in audit but the assignment is real — acceptable
            // trade-off vs adding a new public factory method.
            AssignmentResolver.AssignmentOutcome outcome =
                AssignmentResolver.outcomeDryRun(
                    Id.valueOf(request.recordId), 1
                );

            AuditLogger.AuditEntry auditEntry = AuditLogger.createEntry(
                outcome, matchedBundle, overrideAgent.User__c, entryPoint, null
            );
            List<AuditLogger.AuditEntry> entries =
                new List<AuditLogger.AuditEntry>{ auditEntry };

            List<Id> logIds = AuditLogger.flush(entries);
            RoutingEventPublisher.publishFromAudit(
                entries, request, entryPoint, logIds
            );

            // ── Build result ────────────────────────────────────────────
            RoutingResult rr = RoutingResult.success(
                String.valueOf(request.recordId),
                String.valueOf(overrideAgent.User__c),
                (!logIds.isEmpty() && logIds[0] != null)
                    ? String.valueOf(logIds[0]) : null,
                0
            );
            rr.entryPoint = entryPoint;
            rr.objectApiName = objectApiName;
            rr.reasonSummary = 'Override-assigned to agent '
                + overrideAgent.Id + ' by supervisor.';
            rr.recordName = AssignmentSelector.queryRecordName(
                objectApiName, request.recordId
            );
            return rr;

        } catch (Exception ex) {
            Logger.error('Override exception | recordId=' + request.recordId)
                .category(Logger.Category.ASSIGNMENT)
                .inClass(CLS).inMethod('executeOverride')
                .withException(ex)
                .log();
            return RoutingResult.failure(
                String.valueOf(request.recordId),
                'Override failed: ' + ex.getMessage()
            );
        }
    }
}
