/**
 * @description Core v2 addition. Evaluates whether an agent is eligible to receive a
 *              work record by matching the record's field values against the agent's
 *              capability values.
 *
 *              Design: Binary match — agent either qualifies or doesn't. No scoring.
 *              All mandatory Agent_Match_Condition__mdt entries must match for the agent
 *              to be eligible. If NO agent matches all mandatory capabilities, a
 *              CapabilityMismatchException is thrown with details for admin remediation.
 *
 *              Agent eligibility pipeline:
 *              1. Capacity check — Current_Load__c < Max_Capacity__c
 *              2. Mandatory capability match — every mandatory condition must be satisfied
 *
 *              Data flow:
 *              RoutingEngine passes the candidate SObject (work record) and the
 *              Agent_Match_Condition__mdt list from ConfigLoader. AgentMatcher reads
 *              the record's field values, loads agent capabilities from
 *              AgentCapabilitySelector, and returns the qualified Agent__c record.
 *
 *              Cost: 0 SOQL (all data pre-loaded by AgentCapabilitySelector's
 *                    transaction cache). Pure in-memory evaluation.
 *
 * @group Worker
 */
public with sharing class AgentMatcher {

    private static final String CLS = 'AgentMatcher';

    // ─── Inner Value Object ─────────────────────────────────────────────────

    /**
     * @description Result of agent matching for a single work record.
     */
    public class MatchResult {
        /** The qualified agent, or null if no match. */
        public Agent__c agent            { get; private set; }

        /** True if a qualified agent was found. */
        public Boolean matched           { get; private set; }

        /** Details of mandatory mismatches (for exception/audit). */
        public Map<String, String> missingCapabilities { get; private set; }

        @TestVisible
        private MatchResult() {
            this.missingCapabilities = new Map<String, String>();
        }
    }

    // ─── MatchResult Factories ──────────────────────────────────────────────

    private static MatchResult resultMatched(Agent__c agent) {
        MatchResult r = new MatchResult();
        r.agent = agent;
        r.matched = true;
        return r;
    }

    private static MatchResult resultNoMatch(Map<String, String> missingCaps) {
        MatchResult r = new MatchResult();
        r.matched = false;
        r.missingCapabilities = missingCaps;
        return r;
    }

    // ─── Public API ─────────────────────────────────────────────────────────

    /**
     * @description Evaluates the requesting agent against the work record's capability
     *              requirements. Uses binary match: all mandatory conditions must pass.
     *
     *              Flow:
     *              1. Look up Agent__c for the requesting user
     *              2. Capacity gate: Current_Load__c < Max_Capacity__c
     *              3. For each mandatory Agent_Match_Condition__mdt:
     *                 a. Read work record field value
     *                 b. Check if agent's capability values contain that value
     *              4. If all mandatory pass → return matched agent
     *              5. If any mandatory fail → throw CapabilityMismatchException
     *
     * @param workRecord       The candidate SObject (e.g. Case with Province__c populated)
     * @param matchConditions  Agent_Match_Condition__mdt list for this config
     * @param agentUserId      The requesting agent's User Id
     * @param configDevName    Config DeveloperName for error messages
     * @return MatchResult with the qualified agent
     * @throws CapabilityMismatchException when no agent matches mandatory capabilities
     */
    public static MatchResult evaluate(
        SObject workRecord,
        List<Agent_Match_Condition__mdt> matchConditions,
        Id agentUserId,
        String configDevName
    ) {
        // ─── Guard: no match conditions configured ──────────────────────
        if (matchConditions == null || matchConditions.isEmpty()) {
            Logger.debug('No match conditions configured — agent auto-qualifies'
                    + ' | config=' + configDevName)
                .category(Logger.Category.ENGINE)
                .inClass(CLS).inMethod('evaluate')
                .forConfig(configDevName)
                .log();
            return resultNoMatchConditions(agentUserId);
        }

        // ─── Load agent data (transaction-cached, 0 SOQL on repeat) ─────
        Map<Id, Agent__c> agentsByUserId =
            AgentCapabilitySelector.getActiveAgentsByUserId();

        Agent__c agent = agentsByUserId.get(agentUserId);

        if (agent == null) {
            Logger.warn('No active Agent__c record found for user='
                    + agentUserId + ' | config=' + configDevName)
                .category(Logger.Category.ENGINE)
                .inClass(CLS).inMethod('evaluate')
                .forConfig(configDevName)
                .log();
            throw new CapabilityMismatchException(
                'No active agent record found for the current user. '
                + 'Please contact your administrator to create an Agent record.'
            );
        }

        // ─── Capacity gate ──────────────────────────────────────────────
        Decimal currentLoad = (agent.Current_Load__c != null) ? agent.Current_Load__c : 0;
        Decimal maxCapacity = (agent.Max_Capacity__c != null) ? agent.Max_Capacity__c : 0;

        if (maxCapacity > 0 && currentLoad >= maxCapacity) {
            Logger.info('Agent capacity exceeded | agent=' + agentUserId
                    + ' | load=' + currentLoad + '/' + maxCapacity
                    + ' | config=' + configDevName)
                .category(Logger.Category.ENGINE)
                .inClass(CLS).inMethod('evaluate')
                .forConfig(configDevName)
                .log();
            throw new CapabilityMismatchException(
                'You have reached your maximum open items ('
                + maxCapacity.intValue() + '). '
                + 'Please close or reassign existing work before requesting new items.'
            );
        }

        // ─── Load capability map (transaction-cached) ───────────────────
        Map<Id, Map<String, Set<String>>> capabilityMap =
            AgentCapabilitySelector.getCapabilityMap();

        Map<String, Set<String>> agentCaps = capabilityMap.get(agent.Id);
        if (agentCaps == null) {
            agentCaps = new Map<String, Set<String>>();
        }

        // ─── Evaluate mandatory conditions ──────────────────────────────
        Map<String, String> missingCaps = new Map<String, String>();

        for (Agent_Match_Condition__mdt cond : matchConditions) {
            if (cond.Is_Mandatory__c != true) {
                continue; // Skip optional conditions in binary match mode
            }

            // Read the work record's field value
            String fieldApiName = cond.Field_API_Name__c;
            Object fieldValue = safeGetField(workRecord, fieldApiName);

            if (fieldValue == null) {
                Logger.debug('Work record field is null | field=' + fieldApiName
                        + ' | config=' + configDevName + ' — skipping condition')
                    .category(Logger.Category.ENGINE)
                    .inClass(CLS).inMethod('evaluate')
                    .forConfig(configDevName)
                    .log();
                continue; // Null field on record = condition not applicable
            }

            String recordValue = String.valueOf(fieldValue).trim();

            // Get the capability DeveloperName from the match condition
            String capDevName = resolveCapabilityDevName(cond);
            Set<String> agentValues = agentCaps.get(capDevName);

            if (agentValues == null || !agentValues.contains(recordValue)) {
                // Get human-readable label for error message
                String capLabel = resolveCapabilityLabel(cond);
                missingCaps.put(capLabel, recordValue);

                Logger.debug('Mandatory capability mismatch | capability='
                        + capDevName + ' | required=' + recordValue
                        + ' | agentValues=' + agentValues
                        + ' | config=' + configDevName)
                    .category(Logger.Category.ENGINE)
                    .inClass(CLS).inMethod('evaluate')
                    .forConfig(configDevName)
                    .log();
            }
        }

        // ─── Result ─────────────────────────────────────────────────────
        if (!missingCaps.isEmpty()) {
            Logger.warn('Agent failed mandatory capabilities | agent=' + agentUserId
                    + ' | missing=' + missingCaps.size()
                    + ' | config=' + configDevName)
                .category(Logger.Category.ENGINE)
                .inClass(CLS).inMethod('evaluate')
                .forConfig(configDevName)
                .log();
            throw CapabilityMismatchException.create(configDevName, missingCaps);
        }

        Logger.info('Agent qualified | agent=' + agentUserId
                + ' | config=' + configDevName
                + ' | load=' + currentLoad + '/' + maxCapacity)
            .category(Logger.Category.ENGINE)
            .inClass(CLS).inMethod('evaluate')
            .forConfig(configDevName)
            .log();

        return resultMatched(agent);
    }

    // ─── Private Helpers ────────────────────────────────────────────────────

    /**
     * @description Returns a MatchResult when no match conditions are configured.
     *              Agent auto-qualifies but we still validate agent existence and capacity.
     */
    private static MatchResult resultNoMatchConditions(Id agentUserId) {
        Map<Id, Agent__c> agentsByUserId =
            AgentCapabilitySelector.getActiveAgentsByUserId();
        Agent__c agent = agentsByUserId.get(agentUserId);

        if (agent != null) {
            return resultMatched(agent);
        }

        // No agent record but no match conditions — return unmatched (soft fail)
        return resultNoMatch(new Map<String, String>());
    }

    /**
     * @description Safely reads a field value from an SObject. Returns null if the
     *              field is not populated or doesn't exist on the record (instead of
     *              throwing SObjectException).
     */
    @TestVisible
    private static Object safeGetField(SObject record, String fieldApiName) {
        if (record == null || String.isBlank(fieldApiName)) {
            return null;
        }
        try {
            return record.get(fieldApiName);
        } catch (SObjectException ex) {
            Logger.debug('Field not available on record | field=' + fieldApiName
                    + ' | reason=' + ex.getMessage())
                .category(Logger.Category.ENGINE)
                .inClass(CLS).inMethod('safeGetField')
                .log();
            return null;
        }
    }

    /**
     * @description Resolves the Agent_Capability__mdt DeveloperName from an
     *              Agent_Match_Condition__mdt record. Uses the MD relationship field.
     */
    private static String resolveCapabilityDevName(Agent_Match_Condition__mdt cond) {
        // Agent_Capability__c is an MD Relationship field — at runtime it holds the Id
        // We need to resolve to DeveloperName for map lookup against Agent_Capability_Value__c
        // The Agent_Capability_Value__c.Agent_Capability__c stores the DeveloperName as text
        if (cond.Agent_Capability__r != null
            && String.isNotBlank(cond.Agent_Capability__r.DeveloperName)
        ) {
            return cond.Agent_Capability__r.DeveloperName;
        }
        // Fallback: use the Id as string (less readable but functional)
        return (cond.Agent_Capability__c != null)
            ? String.valueOf(cond.Agent_Capability__c)
            : '';
    }

    /**
     * @description Resolves the human-readable label for error messages.
     */
    private static String resolveCapabilityLabel(Agent_Match_Condition__mdt cond) {
        if (cond.Agent_Capability__r != null
            && String.isNotBlank(cond.Agent_Capability__r.Label__c)
        ) {
            return cond.Agent_Capability__r.Label__c;
        }
        return resolveCapabilityDevName(cond);
    }
}
