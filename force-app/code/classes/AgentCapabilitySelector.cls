/**
 * @description Selector for Agent records and their capability values. Provides a
 *              transaction-cached, Platform-Cache-aware data access layer for the
 *              AgentMatcher.
 *
 *              Caching strategy (two tiers):
 *              1. Transaction cache — static map, populated once per Apex transaction.
 *                 Guarantees zero redundant SOQL even if RoutingEngine processes
 *                 multiple ConfigBundles.
 *              2. Platform Cache (Cache.Org) — optional cross-transaction cache for
 *                 Agent_Capability_Value__c records. Gracefully falls back to SOQL
 *                 if no cache partition is available or the cache is cold. Keyed by
 *                 'ure_agent_caps' with 300s TTL.
 *
 *              Cost: 1–2 SOQL on first call per transaction (agents + capability values).
 *                    0 SOQL on subsequent calls within the same transaction.
 *                    0 SOQL when Platform Cache is warm (cross-transaction).
 *
 * @group Selector
 */
public with sharing class AgentCapabilitySelector {

    private static final String CLS = 'AgentCapabilitySelector';

    // Platform Cache key for capability values
    private static final String CACHE_PARTITION = 'local.URE';
    private static final String CACHE_KEY_CAPS  = 'agent_caps';
    private static final Integer CACHE_TTL_SECS = 300;

    // ─── Transaction Cache ──────────────────────────────────────────────────

    private static Map<Id, Agent__c> cachedAgents;
    private static List<Agent_Capability_Value__c> cachedCapValues;

    // ─── Test Isolation ─────────────────────────────────────────────────────

    @TestVisible
    private static Map<Id, Agent__c> mockAgents;

    @TestVisible
    private static List<Agent_Capability_Value__c> mockCapValues;

    // ─── Public API ─────────────────────────────────────────────────────────

    /**
     * @description Returns all active Agent__c records keyed by User__c (the User Id).
     *              Cached per transaction — 0 SOQL on subsequent calls.
     *
     * @return Map of User Id → Agent__c record. Only active agents included.
     */
    public static Map<Id, Agent__c> getActiveAgentsByUserId() {
        if (cachedAgents != null) {
            return cachedAgents;
        }

        if (Test.isRunningTest() && mockAgents != null) {
            cachedAgents = mockAgents;
            return cachedAgents;
        }

        cachedAgents = new Map<Id, Agent__c>();

        String soql = 'SELECT Id, User__c, Is_Active__c, Max_Capacity__c, '
            + 'Current_Load__c, Last_Assigned__c '
            + 'FROM Agent__c '
            + 'WHERE Is_Active__c = :isActive '
            + 'AND User__c != NULL';

        Map<String, Object> binds = new Map<String, Object>{
            'isActive' => true
        };

        List<SObject> results = Database.queryWithBinds(
            soql, binds, AccessLevel.USER_MODE
        );

        for (SObject rec : results) {
            Agent__c agent = (Agent__c) rec;
            cachedAgents.put(agent.User__c, agent);
        }

        Logger.debug('Active agents loaded | count=' + cachedAgents.size())
            .category(Logger.Category.ENGINE)
            .inClass(CLS).inMethod('getActiveAgentsByUserId')
            .withLimits()
            .log();

        return cachedAgents;
    }

    /**
     * @description Returns all Agent_Capability_Value__c records. Uses Platform Cache
     *              when available, falls back to SOQL. Transaction-cached after first load.
     *
     * @return List of all capability value records (active agents only filtered by caller)
     */
    public static List<Agent_Capability_Value__c> getAllCapabilityValues() {
        if (cachedCapValues != null) {
            return cachedCapValues;
        }

        if (Test.isRunningTest() && mockCapValues != null) {
            cachedCapValues = mockCapValues;
            return cachedCapValues;
        }

        // Tier 2: Try Platform Cache
        cachedCapValues = getFromPlatformCache();

        if (cachedCapValues != null) {
            Logger.debug('Capability values loaded from Platform Cache'
                    + ' | count=' + cachedCapValues.size())
                .category(Logger.Category.ENGINE)
                .inClass(CLS).inMethod('getAllCapabilityValues')
                .log();
            return cachedCapValues;
        }

        // Tier 3: SOQL fallback
        String soql = 'SELECT Id, Agent__c, Agent_Capability__c, Values__c '
            + 'FROM Agent_Capability_Value__c';

        cachedCapValues = Database.queryWithBinds(
            soql, new Map<String, Object>(), AccessLevel.USER_MODE
        );

        // Attempt to warm Platform Cache for next transaction
        putToPlatformCache(cachedCapValues);

        Logger.debug('Capability values loaded from SOQL'
                + ' | count=' + cachedCapValues.size())
            .category(Logger.Category.ENGINE)
            .inClass(CLS).inMethod('getAllCapabilityValues')
            .withLimits()
            .log();

        return cachedCapValues;
    }

    /**
     * @description Builds a nested map: Agent__c Id → Capability DeveloperName → Set of values.
     *              Parses comma and semicolon delimited Values__c into clean individual values.
     *
     * @return Map<Id, Map<String, Set<String>>> — agentId → capabilityDevName → parsed values
     */
    public static Map<Id, Map<String, Set<String>>> getCapabilityMap() {
        Map<Id, Agent__c> agents = getActiveAgentsByUserId();
        List<Agent_Capability_Value__c> capValues = getAllCapabilityValues();

        // Build set of active agent Ids for filtering
        Set<Id> activeAgentIds = new Set<Id>();
        for (Agent__c agent : agents.values()) {
            activeAgentIds.add(agent.Id);
        }

        Map<Id, Map<String, Set<String>>> result =
            new Map<Id, Map<String, Set<String>>>();

        for (Agent_Capability_Value__c cv : capValues) {
            // Skip capability values for inactive agents
            if (!activeAgentIds.contains(cv.Agent__c)) {
                continue;
            }

            if (!result.containsKey(cv.Agent__c)) {
                result.put(cv.Agent__c, new Map<String, Set<String>>());
            }

            Map<String, Set<String>> agentCaps = result.get(cv.Agent__c);
            Set<String> parsedValues = parseDelimitedValues(cv.Values__c);

            if (!agentCaps.containsKey(cv.Agent_Capability__c)) {
                agentCaps.put(cv.Agent_Capability__c, new Set<String>());
            }
            agentCaps.get(cv.Agent_Capability__c).addAll(parsedValues);
        }

        return result;
    }

    /**
     * @description Clears both the transaction cache and Platform Cache.
     *              Called after agent capability updates to ensure fresh data.
     */
    public static void clearCache() {
        cachedAgents = null;
        cachedCapValues = null;
        clearPlatformCache();
    }

    // ─── Delimiter Parsing ──────────────────────────────────────────────────

    /**
     * @description Parses a comma-and-semicolon-delimited string into a clean Set
     *              of trimmed, non-blank, case-preserved values.
     *              Supports: "Ontario,Quebec" or "Ontario;Quebec" or "Ontario, Quebec;BC"
     *
     * @param raw The raw delimited string from Values__c
     * @return Set of individual values. Empty set if input is blank.
     */
    @TestVisible
    private static Set<String> parseDelimitedValues(String raw) {
        Set<String> result = new Set<String>();
        if (String.isBlank(raw)) {
            return result;
        }
        // Split on comma or semicolon
        for (String item : raw.split('[,;]')) {
            String trimmed = item.trim();
            if (String.isNotBlank(trimmed)) {
                result.add(trimmed);
            }
        }
        return result;
    }

    // ─── Platform Cache Helpers ─────────────────────────────────────────────

    /**
     * @description Attempts to read capability values from Platform Cache.
     *              Returns null if cache partition unavailable or key is cold.
     */
    private static List<Agent_Capability_Value__c> getFromPlatformCache() {
        try {
            Cache.OrgPartition partition = Cache.Org.getPartition(CACHE_PARTITION);
            if (partition == null) {
                return null;
            }
            Object cached = partition.get(CACHE_KEY_CAPS);
            if (cached instanceof List<Agent_Capability_Value__c>) {
                return (List<Agent_Capability_Value__c>) cached;
            }
        } catch (Exception ex) {
            // Cache partition not configured — graceful fallback
            Logger.debug('Platform Cache unavailable, falling back to SOQL'
                    + ' | reason=' + ex.getMessage())
                .category(Logger.Category.ENGINE)
                .inClass(CLS).inMethod('getFromPlatformCache')
                .log();
        }
        return null;
    }

    /**
     * @description Attempts to write capability values to Platform Cache.
     *              Silently fails if cache partition is unavailable.
     */
    private static void putToPlatformCache(List<Agent_Capability_Value__c> values) {
        try {
            Cache.OrgPartition partition = Cache.Org.getPartition(CACHE_PARTITION);
            if (partition != null) {
                partition.put(CACHE_KEY_CAPS, values, CACHE_TTL_SECS);
            }
        } catch (Exception ex) {
            // Non-fatal — cache warming is best-effort
            Logger.debug('Platform Cache write failed | reason=' + ex.getMessage())
                .category(Logger.Category.ENGINE)
                .inClass(CLS).inMethod('putToPlatformCache')
                .log();
        }
    }

    /**
     * @description Clears Platform Cache entry for capability values.
     */
    private static void clearPlatformCache() {
        try {
            Cache.OrgPartition partition = Cache.Org.getPartition(CACHE_PARTITION);
            if (partition != null) {
                partition.remove(CACHE_KEY_CAPS);
            }
        } catch (Exception ex) {
            // Non-fatal
        }
    }
}
