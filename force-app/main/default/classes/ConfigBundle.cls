/**
 * @description Value object that holds a single routing configuration with its associated
 *              conditions, priorities, and v6 skill mappings. Created by ConfigLoader —
 *              one bundle per active Routing_Config__mdt record.
 *
 *              Implements Comparable to allow List<ConfigBundle>.sort() by Priority_Weight__c
 *              (lower weight = higher priority = earlier in list).
 *
 *              Pre-parses comma-delimited config fields once during construction so
 *              downstream consumers (DynamicQueryBuilder, RoutingEngine, AssignmentResolver,
 *              AgentMatcher) never repeat parsing logic.
 *
 *              v6 changes:
 *              • matchConditions — Routing_Skill_Mapping__mdt list for AgentMatcher
 *              • maxRetryAttempts — admin-configurable lock retry count (default 1)
 *
 * @group Worker
 */
public with sharing class ConfigBundle implements Comparable {

    // ─── Raw CMDT records ────────────────────────────────────────────────────

    public Routing_Config__mdt config;
    public List<Routing_Condition__mdt> conditions;
    public List<Routing_Priority__mdt> priorities;
    public List<Routing_Skill_Mapping__mdt> matchConditions;

    // ─── Pre-parsed convenience values ───────────────────────────────────────

    public String developerName;
    public String objectApiName;
    public String ownerFieldApiName;
    public Integer candidateLimit;
    public Boolean ignoreCapacity;
    public Integer maxCapacity;
    public String preAssignmentOwnerType;
    public String closedStatusFieldApiName;
    public List<String> closedStatusValues;
    public List<String> recordTypeDevNames;
    public List<String> selectFields;
    public Integer maxRetryAttempts;
    public Boolean includeBusyAgents;
    public Decimal slaMinutes;

    // ─── P2 Escalation fields ───────────────────────────────────────────────
    public Boolean escalationEnabled;
    public Decimal escalationThresholdPct;
    public String  escalationAction;
    public String  actedOnField;
    public String  actedOnValue;
    public List<String> actedOnValues;
    public String  escalationNotifyEmail;
    public String  escalationReturnOwner;
    public String  slaDeadlineField;

    // ─── Constructor ─────────────────────────────────────────────────────────

    /**
     * @description Builds a bundle from a config and its child records. Sorts conditions
     *              and priorities by Sort_Order__c ascending. Pre-parses comma-delimited
     *              config fields.
     *
     * @param config          The parent Routing Config CMDT record
     * @param conditions      Active conditions for this config (filtered upstream)
     * @param priorities      Priority sort specs for this config
     * @param matchConditions v2: Agent Match Conditions for this config (may be empty)
     */
    public ConfigBundle(
        Routing_Config__mdt config,
        List<Routing_Condition__mdt> conditions,
        List<Routing_Priority__mdt> priorities,
        List<Routing_Skill_Mapping__mdt> matchConditions
    ) {
        this.config = config;
        this.conditions = sortConditions(conditions);
        this.priorities = sortPriorities(priorities);
        this.matchConditions = (matchConditions != null)
            ? matchConditions
            : new List<Routing_Skill_Mapping__mdt>();

        this.developerName = config.DeveloperName;
        this.objectApiName = config.Object_API_Name__c;
        this.ownerFieldApiName = config.Owner_Field_API_Name__c;
        this.candidateLimit = (config.Candidate_Limit__c != null)
            ? config.Candidate_Limit__c.intValue()
            : 50;
        // Ignore_Capacity__c is the master switch for the Phase 3 Open Work
        // Item Gate. When TRUE the gate is skipped entirely (unlimited).
        // When FALSE (default) Max_Capacity__c is enforced — or 1 if null.
        this.ignoreCapacity = (config.Ignore_Capacity__c == true);
        // Nullable on purpose:
        //   null  → admin did not configure a per-config cap → falls back
        //           to legacy default of 1 (unless ignoreCapacity=true)
        //   N>=1  → admin explicitly set a per-config cap → enforced when
        //           ignoreCapacity is false
        this.maxCapacity = (config.Max_Capacity__c != null
                && config.Max_Capacity__c > 0)
            ? config.Max_Capacity__c.intValue()
            : null;
        this.preAssignmentOwnerType = config.Pre_Assignment_Owner_Type__c;
        this.closedStatusFieldApiName = config.Closed_Status_Field_API_Name__c;
        this.closedStatusValues = parseCommaDelimited(config.Closed_Status_Values__c);
        this.recordTypeDevNames = parseCommaDelimited(config.Record_Type_Dev_Name__c);
        this.selectFields = parseCommaDelimited(config.Select_Fields__c);
        this.maxRetryAttempts = (config.Max_Retry_Attempts__c != null)
            ? config.Max_Retry_Attempts__c.intValue()
            : 1;
        this.includeBusyAgents = (config.Include_Busy_Agents__c == true);
        this.slaMinutes = config.SLA_Minutes__c;

        // P2 Escalation fields
        this.escalationEnabled = (config.Escalation_Enabled__c == true);
        this.escalationThresholdPct = config.Escalation_Threshold_Pct__c;
        this.escalationAction = config.Escalation_Action__c;
        this.actedOnField = config.Acted_On_Field__c;
        this.actedOnValue = config.Acted_On_Value__c;
        this.actedOnValues = parseCommaDelimited(config.Acted_On_Value__c);
        this.escalationNotifyEmail = config.Escalation_Notify_Email__c;
        this.escalationReturnOwner = config.Escalation_Return_Owner__c;
        this.slaDeadlineField = config.SLA_Deadline_Field__c;
    }

    /**
     * @description Backward-compatible constructor for existing code and tests.
     *              Creates a bundle with an empty matchConditions list.
     */
    public ConfigBundle(
        Routing_Config__mdt config,
        List<Routing_Condition__mdt> conditions,
        List<Routing_Priority__mdt> priorities
    ) {
        this(config, conditions, priorities, new List<Routing_Skill_Mapping__mdt>());
    }

    // ─── Comparable — sort bundles by Priority_Weight__c ascending ────────────

    public Integer compareTo(Object other) {
        ConfigBundle otherBundle = (ConfigBundle) other;
        Integer thisWeight = (this.config.Priority_Weight__c != null)
            ? this.config.Priority_Weight__c.intValue()
            : 999999;
        Integer otherWeight = (otherBundle.config.Priority_Weight__c != null)
            ? otherBundle.config.Priority_Weight__c.intValue()
            : 999999;
        if (thisWeight < otherWeight) {
            return -1;
        }
        if (thisWeight > otherWeight) {
            return 1;
        }
        return 0;
    }

    // ─── Private helpers ─────────────────────────────────────────────────────

    /**
     * @description Splits a comma-delimited string into a trimmed, non-blank list.
     */
    private static List<String> parseCommaDelimited(String value) {
        List<String> result = new List<String>();
        if (String.isBlank(value)) {
            return result;
        }
        for (String item : value.split(',')) {
            String trimmed = item.trim();
            if (String.isNotBlank(trimmed)) {
                result.add(trimmed);
            }
        }
        return result;
    }

    /**
     * @description Sorts conditions by Sort_Order__c ascending. Null sort order
     *              falls to the end. Uses Map + sorted key list to avoid Comparable
     *              wrappers on CMDT records.
     */
    private static List<Routing_Condition__mdt> sortConditions(
        List<Routing_Condition__mdt> unsorted
    ) {
        if (unsorted == null || unsorted.isEmpty()) {
            return new List<Routing_Condition__mdt>();
        }
        if (unsorted.size() == 1) {
            return unsorted;
        }

        Map<Decimal, List<Routing_Condition__mdt>> grouped =
            new Map<Decimal, List<Routing_Condition__mdt>>();
        List<Decimal> sortKeys = new List<Decimal>();

        for (Routing_Condition__mdt c : unsorted) {
            Decimal key = (c.Sort_Order__c != null) ? c.Sort_Order__c : 999999;
            if (!grouped.containsKey(key)) {
                grouped.put(key, new List<Routing_Condition__mdt>());
                sortKeys.add(key);
            }
            grouped.get(key).add(c);
        }

        sortKeys.sort();

        List<Routing_Condition__mdt> sorted = new List<Routing_Condition__mdt>();
        for (Decimal key : sortKeys) {
            sorted.addAll(grouped.get(key));
        }
        return sorted;
    }

    /**
     * @description Sorts priorities by Sort_Order__c ascending. Same pattern as
     *              sortConditions — separated to avoid SObject casting issues in Apex.
     */
    private static List<Routing_Priority__mdt> sortPriorities(
        List<Routing_Priority__mdt> unsorted
    ) {
        if (unsorted == null || unsorted.isEmpty()) {
            return new List<Routing_Priority__mdt>();
        }
        if (unsorted.size() == 1) {
            return unsorted;
        }

        Map<Decimal, List<Routing_Priority__mdt>> grouped =
            new Map<Decimal, List<Routing_Priority__mdt>>();
        List<Decimal> sortKeys = new List<Decimal>();

        for (Routing_Priority__mdt p : unsorted) {
            Decimal key = (p.Sort_Order__c != null) ? p.Sort_Order__c : 999999;
            if (!grouped.containsKey(key)) {
                grouped.put(key, new List<Routing_Priority__mdt>());
                sortKeys.add(key);
            }
            grouped.get(key).add(p);
        }

        sortKeys.sort();

        List<Routing_Priority__mdt> sorted = new List<Routing_Priority__mdt>();
        for (Decimal key : sortKeys) {
            sorted.addAll(grouped.get(key));
        }
        return sorted;
    }
}
