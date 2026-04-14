/**
 * @description Binary agent matcher: agent either qualifies or doesn't (no scoring).
 *              All mandatory Routing_Skill_Mapping__mdt entries must match.
 *              Data flow: RoutingEngine passes work record + skill mappings from ConfigLoader.
 *              Cost: 0 SOQL — pure in-memory evaluation via AgentCapabilitySelector cache.
 * @group Worker
 */
public with sharing class AgentMatcher {

    private static final String CLS = 'AgentMatcher';

    /** @description Result of agent matching for a single work record. */
    public class MatchResult {
        /** The qualified agent, or null if no match. */
        public Agent__c agent            { get; private set; }
        /** True if a qualified agent was found. */
        public Boolean matched           { get; private set; }
        /** Details of mandatory mismatches (for exception/audit). */
        public Map<String, String> missingCapabilities { get; private set; }
        /** Layer 4 skill match traces — consumed by RoutingEngine for RoutingResult. */
        public List<RoutingConditionTrace> skillTraces { get; private set; }

        @TestVisible
        private MatchResult() {
            this.missingCapabilities = new Map<String, String>();
            this.skillTraces = new List<RoutingConditionTrace>();
        }
    }

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

    /**
     * @description Evaluates the requesting agent against the work record's capability
     *              requirements. Binary match: all mandatory conditions must pass.
     * @param workRecord       The candidate SObject (e.g. Case with Province__c populated)
     * @param matchConditions  Routing_Skill_Mapping__mdt list for this config
     * @param agentUserId      The requesting agent's User Id
     * @param configDevName    Config DeveloperName for error messages
     * @return MatchResult with the qualified agent
     * @throws CapabilityMismatchException when no agent matches mandatory capabilities
     */
    public static MatchResult evaluate(
        SObject workRecord,
        List<Routing_Skill_Mapping__mdt> matchConditions,
        Id agentUserId,
        String configDevName
    ) {
        if (matchConditions == null || matchConditions.isEmpty()) {
            return resultNoMatchConditions(agentUserId);
        }

        Map<Id, Agent__c> agentsByUserId = AgentCapabilitySelector.getActiveAgentsByUserId();
        Agent__c agent = agentsByUserId.get(agentUserId);

        if (agent == null) {
            Logger.warn('No active Agent__c record found for user='
                    + agentUserId + ' | config=' + configDevName)
                .category(Logger.Category.ENGINE)
                .inClass(CLS).inMethod('evaluate')
                .forConfig(configDevName)
                .log();
            throw new CapabilityMismatchException(System.Label.URE_MATCHER_NO_AGENT);
        }

        Decimal currentLoad = agent.Current_Load__c != null ? agent.Current_Load__c : 0;
        Decimal maxCapacity = agent.Max_Capacity__c != null ? agent.Max_Capacity__c : 0;

        if (maxCapacity > 0 && currentLoad >= maxCapacity) {
            Logger.info('Agent capacity exceeded | agent=' + agentUserId
                    + ' | load=' + currentLoad + '/' + maxCapacity
                    + ' | config=' + configDevName)
                .category(Logger.Category.ENGINE)
                .inClass(CLS).inMethod('evaluate')
                .forConfig(configDevName)
                .log();
            throw new CapabilityMismatchException(
                String.format(
                    System.Label.URE_MATCHER_CAPACITY_EXCEEDED,
                    new List<Object>{maxCapacity.intValue()}
                )
            );
        }

        Map<Id, Map<String, Set<String>>> capabilityMap = AgentCapabilitySelector.getCapabilityMap();
        Map<String, Set<String>> agentCaps = capabilityMap.get(agent.Id);
        if (agentCaps == null) {
            agentCaps = new Map<String, Set<String>>();
        }

        Map<String, String> missingCaps = new Map<String, String>();
        List<RoutingConditionTrace> skillTraces = new List<RoutingConditionTrace>();

        for (Routing_Skill_Mapping__mdt cond : matchConditions) {
            if (cond.Is_Mandatory__c != true) {
                continue;
            }

            String fieldApiName = cond.Field_API_Name__c;
            Object fieldValue = safeGetField(workRecord, fieldApiName);

            if (fieldValue == null) {
                skillTraces.add(buildSkillTrace(cond, '', true, agentCaps));
                continue;
            }

            String recordValue = String.valueOf(fieldValue).trim();
            String capDevName = resolveCapabilityDevName(cond);
            Set<String> agentValues = agentCaps.get(capDevName);
            Boolean matched = (agentValues != null && agentValues.contains(recordValue));

            skillTraces.add(buildSkillTrace(cond, recordValue, matched, agentCaps));

            if (!matched) {
                missingCaps.put(resolveCapabilityLabel(cond), recordValue);
            }
        }

        if (!missingCaps.isEmpty()) {
            Logger.warn('Agent failed mandatory capabilities | agent=' + agentUserId
                    + ' | missing=' + missingCaps.size()
                    + ' | config=' + configDevName)
                .category(Logger.Category.ENGINE)
                .inClass(CLS).inMethod('evaluate')
                .forConfig(configDevName)
                .log();

            MatchResult noMatch = resultNoMatch(missingCaps);
            noMatch.skillTraces = skillTraces;
            throw CapabilityMismatchException.create(configDevName, missingCaps);
        }

        MatchResult matched = resultMatched(agent);
        matched.skillTraces = skillTraces;
        return matched;
    }

    /**
     * @description TYPE-level pre-filter: checks agent has at least one value for every
     *              mandatory capability type. 0 SOQL — uses transaction-cached capability map.
     * @param matchConditions Routing_Skill_Mapping__mdt list for a config
     * @param agentUserId    The requesting agent's User Id
     * @return True if agent has all required capability types (or no mandatory conditions exist)
     */
    public static Boolean hasRequiredCapabilityTypes(
        List<Routing_Skill_Mapping__mdt> matchConditions,
        Id agentUserId
    ) {
        if (matchConditions == null || matchConditions.isEmpty()) {
            return true;
        }

        List<String> mandatoryTypes = new List<String>();
        for (Routing_Skill_Mapping__mdt cond : matchConditions) {
            if (cond.Is_Mandatory__c == true) {
                mandatoryTypes.add(resolveCapabilityDevName(cond));
            }
        }

        if (mandatoryTypes.isEmpty()) {
            return true;
        }

        Map<Id, Agent__c> agentsByUserId = AgentCapabilitySelector.getActiveAgentsByUserId();
        Agent__c agent = agentsByUserId.get(agentUserId);
        if (agent == null) {
            return false;
        }

        Map<Id, Map<String, Set<String>>> capabilityMap = AgentCapabilitySelector.getCapabilityMap();
        Map<String, Set<String>> agentCaps = capabilityMap.get(agent.Id);
        if (agentCaps == null || agentCaps.isEmpty()) {
            return false;
        }

        for (String capType : mandatoryTypes) {
            if (!agentCaps.containsKey(capType)) {
                return false;
            }
        }

        return true;
    }

    /** @description Returns a MatchResult when no match conditions are configured. */
    private static MatchResult resultNoMatchConditions(Id agentUserId) {
        Map<Id, Agent__c> agentsByUserId = AgentCapabilitySelector.getActiveAgentsByUserId();
        Agent__c agent = agentsByUserId.get(agentUserId);
        if (agent != null) {
            return resultMatched(agent);
        }
        return resultNoMatch(new Map<String, String>());
    }

    /** @description Safely reads a field value; returns null if not populated or missing. */
    @TestVisible
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

    /** @description Resolves Agent_Skill__mdt DeveloperName from a Routing_Skill_Mapping__mdt record. */
    private static String resolveCapabilityDevName(Routing_Skill_Mapping__mdt cond) {
        if (cond.Agent_Skill__r != null && String.isNotBlank(cond.Agent_Skill__r.DeveloperName)) {
            return cond.Agent_Skill__r.DeveloperName;
        }
        return (cond.Agent_Skill__c != null) ? String.valueOf(cond.Agent_Skill__c) : '';
    }

    /** @description Resolves the human-readable label for error messages. */
    private static String resolveCapabilityLabel(Routing_Skill_Mapping__mdt cond) {
        if (cond.Agent_Skill__r != null && String.isNotBlank(cond.Agent_Skill__r.Label__c)) {
            return cond.Agent_Skill__r.Label__c;
        }
        return resolveCapabilityDevName(cond);
    }

    /** @description Builds a SKILL_MATCH trace for a single Routing_Skill_Mapping__mdt evaluation. */
    private static RoutingConditionTrace buildSkillTrace(
        Routing_Skill_Mapping__mdt cond,
        String recordValue,
        Boolean passed,
        Map<String, Set<String>> agentCaps
    ) {
        String capDevName = resolveCapabilityDevName(cond);
        Set<String> agentValues = agentCaps.get(capDevName);
        String expectedValue = (agentValues != null && !agentValues.isEmpty())
            ? String.join(new List<String>(agentValues), ', ') : '(none)';

        RoutingConditionTrace trace = RoutingConditionTrace.create(
            cond.Field_API_Name__c, 'SKILL_MATCH', expectedValue, recordValue, passed
        );
        trace.traceSource = 'SKILL_MATCH';
        return trace;
    }
}
