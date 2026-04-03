/**
 * @description Selector for Agent records and their skill profiles resolved via the
 *              Skill Bundle pattern (v6). Provides a transaction-cached, Platform-Cache-aware
 *              data access layer for the AgentMatcher.
 *
 *              v6 Skill Bundle pipeline:
 *              1. Load active Agent__c records (1 SOQL, transaction-cached)
 *              2. Load active Agent_Skill_Assignment__c records (1 SOQL, transaction-cached)
 *              3. Load Skill_Bundle_Entry__c for active bundles (1 SOQL, platform + txn cached)
 *              4. Merge: for each agent -> for each bundle -> UNION all entry values
 *              5. Output: Map<AgentId, Map<SkillDevName, Set<Values>>>
 *
 *              Merge semantics: UNION (always additive). When an agent has multiple bundles
 *              defining the same skill dimension, all values are unioned. No replace, no subtract.
 *
 *              Caching strategy (two tiers):
 *              1. Transaction cache — static maps, populated once per Apex transaction.
 *                 Guarantees zero redundant SOQL even if RoutingEngine processes
 *                 multiple ConfigBundles.
 *              2. Platform Cache (Cache.Org) — cross-transaction cache for
 *                 Skill_Bundle_Entry__c records (shared across agents, small volume).
 *                 Gracefully falls back to SOQL if no cache partition is available.
 *
 *              Cost: 2-3 SOQL on first call per transaction (agents + assignments + entries).
 *                    0 SOQL on subsequent calls within the same transaction.
 *                    1-2 SOQL when Platform Cache is warm (entries cached cross-transaction).
 *
 * @group Selector
 */
public with sharing class AgentCapabilitySelector {

    private static final String CLS = 'AgentCapabilitySelector';

    // Platform Cache key for bundle entries (shared across agents — small volume)
    private static final String CACHE_PARTITION = 'local.URE';
    private static final String CACHE_KEY_ENTRIES = 'skill_bundle_entries';
    private static final Integer CACHE_TTL_SECS = 300;

    // ─── Transaction Cache ──────────────────────────────────────────────────

    private static Map<Id, Agent__c> cachedAgents;
    private static List<Agent_Skill_Assignment__c> cachedAssignments;
    private static List<Skill_Bundle_Entry__c> cachedEntries;

    // ─── Test Isolation ─────────────────────────────────────────────────────

    @TestVisible
    private static Map<Id, Agent__c> mockAgents;

    @TestVisible
    private static List<Agent_Skill_Assignment__c> mockAssignments;

    @TestVisible
    private static List<Skill_Bundle_Entry__c> mockEntries;

    // ─── Public API ─────────────────────────────────────────────────────────

    /**
     * @description Returns all active Agent__c records keyed by User__c (the User Id).
     *              Cached per transaction — 0 SOQL on subsequent calls.
     *
     * @return Map of User Id -> Agent__c record. Only active agents included.
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

        return cachedAgents;
    }

    /**
     * @description Returns all active Agent_Skill_Assignment__c records.
     *              Transaction-cached after first load.
     *
     * @return List of active skill assignments
     */
    public static List<Agent_Skill_Assignment__c> getActiveAssignments() {
        if (cachedAssignments != null) {
            return cachedAssignments;
        }

        if (Test.isRunningTest() && mockAssignments != null) {
            cachedAssignments = mockAssignments;
            return cachedAssignments;
        }

        String soql = 'SELECT Id, Agent__c, Skill_Bundle__c, Is_Active__c '
            + 'FROM Agent_Skill_Assignment__c '
            + 'WHERE Is_Active__c = :isActive';

        Map<String, Object> binds = new Map<String, Object>{
            'isActive' => true
        };

        cachedAssignments = Database.queryWithBinds(
            soql, binds, AccessLevel.USER_MODE
        );

        return cachedAssignments;
    }

    /**
     * @description Returns all Skill_Bundle_Entry__c records for active bundles.
     *              Uses Platform Cache when available, falls back to SOQL.
     *              Transaction-cached after first load.
     *
     * @return List of all bundle entry records for active bundles
     */
    public static List<Skill_Bundle_Entry__c> getAllBundleEntries() {
        if (cachedEntries != null) {
            return cachedEntries;
        }

        if (Test.isRunningTest() && mockEntries != null) {
            cachedEntries = mockEntries;
            return cachedEntries;
        }

        // Tier 2: Try Platform Cache
        cachedEntries = getFromPlatformCache();

        if (cachedEntries != null) {
            return cachedEntries;
        }

        // Tier 3: SOQL fallback — only entries for active bundles
        String soql = 'SELECT Id, Skill_Bundle__c, Agent_Skill__c, Values__c '
            + 'FROM Skill_Bundle_Entry__c '
            + 'WHERE Skill_Bundle__r.Is_Active__c = :isActive';

        Map<String, Object> binds = new Map<String, Object>{
            'isActive' => true
        };

        cachedEntries = Database.queryWithBinds(
            soql, binds, AccessLevel.USER_MODE
        );

        // Attempt to warm Platform Cache for next transaction
        putToPlatformCache(cachedEntries);

        return cachedEntries;
    }

    /**
     * @description Builds a nested map: Agent__c Id -> Skill DeveloperName -> Set of values.
     *              Resolves skills via the Skill Bundle pattern:
     *              1. Get agent -> bundle assignments
     *              2. Get bundle -> entry values
     *              3. Merge using UNION semantics (additive across bundles)
     *
     *              Output signature is IDENTICAL to v5 — AgentMatcher sees no change.
     *
     * @return Map<Id, Map<String, Set<String>>> — agentId -> skillDevName -> parsed values
     */
    public static Map<Id, Map<String, Set<String>>> getCapabilityMap() {
        Map<Id, Agent__c> agents = getActiveAgentsByUserId();
        List<Agent_Skill_Assignment__c> assignments = getActiveAssignments();
        List<Skill_Bundle_Entry__c> entries = getAllBundleEntries();

        // Build set of active agent Ids for filtering
        Set<Id> activeAgentIds = new Set<Id>();
        for (Agent__c agent : agents.values()) {
            activeAgentIds.add(agent.Id);
        }

        // Step 1: Build agent -> Set<bundleId> map
        Map<Id, Set<Id>> agentToBundles = new Map<Id, Set<Id>>();
        for (Agent_Skill_Assignment__c assignment : assignments) {
            if (!activeAgentIds.contains(assignment.Agent__c)) {
                continue;
            }
            if (!agentToBundles.containsKey(assignment.Agent__c)) {
                agentToBundles.put(assignment.Agent__c, new Set<Id>());
            }
            agentToBundles.get(assignment.Agent__c).add(assignment.Skill_Bundle__c);
        }

        // Step 2: Validate Agent_Skill__c text values against Agent_Skill__mdt
        //         (GAP 2 mitigation — Skill_Bundle_Entry__c.Agent_Skill__c is text,
        //          not a lookup, so referential integrity is not enforced by the platform)
        Map<String, Agent_Skill__mdt> validSkills =
            RoutingConfigSelector.getAllSkills();

        // Step 3: Build bundle -> Map<skillDevName, Set<values>> map
        Map<Id, Map<String, Set<String>>> bundleSkillMap =
            new Map<Id, Map<String, Set<String>>>();

        for (Skill_Bundle_Entry__c entry : entries) {
            // Validate skill reference — warn on orphan text values
            if (String.isNotBlank(entry.Agent_Skill__c)
                && !validSkills.containsKey(entry.Agent_Skill__c)
            ) {
                Logger.warn('Skill_Bundle_Entry__c references unknown Agent_Skill__mdt'
                        + ' | Agent_Skill__c=' + entry.Agent_Skill__c
                        + ' | Entry Id=' + entry.Id
                        + ' — this entry will not match any routing skill mapping')
                    .category(Logger.Category.VALIDATION)
                    .inClass(CLS).inMethod('getCapabilityMap')
                    .log();
            }
            if (!bundleSkillMap.containsKey(entry.Skill_Bundle__c)) {
                bundleSkillMap.put(
                    entry.Skill_Bundle__c,
                    new Map<String, Set<String>>()
                );
            }

            Map<String, Set<String>> skillMap = bundleSkillMap.get(entry.Skill_Bundle__c);
            Set<String> parsedValues = parseDelimitedValues(entry.Values__c);

            if (!skillMap.containsKey(entry.Agent_Skill__c)) {
                skillMap.put(entry.Agent_Skill__c, new Set<String>());
            }
            skillMap.get(entry.Agent_Skill__c).addAll(parsedValues);
        }

        // Step 4: Merge — for each agent, UNION all bundle entries
        Map<Id, Map<String, Set<String>>> result =
            new Map<Id, Map<String, Set<String>>>();

        for (Id agentId : agentToBundles.keySet()) {
            Map<String, Set<String>> agentSkills = new Map<String, Set<String>>();

            for (Id bundleId : agentToBundles.get(agentId)) {
                Map<String, Set<String>> bundleSkills = bundleSkillMap.get(bundleId);
                if (bundleSkills == null) {
                    continue;
                }

                // UNION semantics: additive merge across bundles
                for (String skillDevName : bundleSkills.keySet()) {
                    if (!agentSkills.containsKey(skillDevName)) {
                        agentSkills.put(skillDevName, new Set<String>());
                    }
                    agentSkills.get(skillDevName).addAll(bundleSkills.get(skillDevName));
                }
            }

            result.put(agentId, agentSkills);
        }

        return result;
    }

    /**
     * @description Clears both the transaction cache and Platform Cache.
     *              Called after skill bundle updates to ensure fresh data.
     */
    public static void clearCache() {
        cachedAgents = null;
        cachedAssignments = null;
        cachedEntries = null;
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
     * @description Attempts to read bundle entries from Platform Cache.
     *              Returns null if cache partition unavailable or key is cold.
     */
    private static List<Skill_Bundle_Entry__c> getFromPlatformCache() {
        try {
            Cache.OrgPartition partition = Cache.Org.getPartition(CACHE_PARTITION);
            if (partition == null) {
                return null;
            }
            Object cached = partition.get(CACHE_KEY_ENTRIES);
            if (cached instanceof List<Skill_Bundle_Entry__c>) {
                return (List<Skill_Bundle_Entry__c>) cached;
            }
        } catch (Exception ex) {
            // Cache partition not configured — graceful fallback
        }
        return null;
    }

    /**
     * @description Attempts to write bundle entries to Platform Cache.
     *              Silently fails if cache partition is unavailable.
     */
    private static void putToPlatformCache(List<Skill_Bundle_Entry__c> values) {
        try {
            Cache.OrgPartition partition = Cache.Org.getPartition(CACHE_PARTITION);
            if (partition != null) {
                partition.put(CACHE_KEY_ENTRIES, values, CACHE_TTL_SECS);
            }
        } catch (Exception ex) {
            // Non-fatal — cache warming is best-effort
        }
    }

    /**
     * @description Clears Platform Cache entry for bundle entries.
     */
    private static void clearPlatformCache() {
        try {
            Cache.OrgPartition partition = Cache.Org.getPartition(CACHE_PARTITION);
            if (partition != null) {
                partition.remove(CACHE_KEY_ENTRIES);
            }
        } catch (Exception ex) {
            // Non-fatal
        }
    }
}
