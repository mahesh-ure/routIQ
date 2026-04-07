/**
 * @description Selector providing aggregate queries on Routing_Log__c for the
 *              Analytics Dashboard (P2 Feature 1). Three lenses:
 *
 *              1. Routing Velocity — avg Assignment_Duration_Ms__c trended daily
 *              2. SLA Compliance  — % Met vs Breached by config and by agent
 *              3. Agent Utilisation — assigned count vs max capacity per agent per day
 *
 *              Performance design:
 *              • All queries bounded to LAST_N_DAYS via Routed_At__c (configurable)
 *              • GROUP BY with LIMIT caps result set size (configurable)
 *              • AccessLevel.USER_MODE enforces FLS — no stripInaccessible needed
 *              • Bind variables only — zero SOQL injection surface
 *              • Zero business logic — pure data access
 *
 *              Configuration:
 *              All tunable values read from Analytics_Settings__c (Hierarchy Custom
 *              Setting) via getInstance() — zero SOQL, subscriber-controlled,
 *              supports org-wide defaults with per-user/profile overrides.
 *
 *              Governor cost: 1 SOQL per lens (3 total for full dashboard load).
 *
 * @group Selector
 */
public with sharing class RoutingAnalyticsSelector {

    private static final String SUCCESS_STATUS = 'Success';

    // ─── Compile-time safety nets — used ONLY when Custom Setting
    //     record does not exist (fresh install before admin setup).
    //     In production, values always come from Analytics_Settings__c.
    private static final Integer FALLBACK_DAYS = 30;
    private static final Integer FALLBACK_MAX_ROWS = 1000;

    // ─── Test Isolation ───────────────────────────────────────────────────────

    @TestVisible
    private static List<AggregateResult> mockVelocityResults;
    @TestVisible
    private static List<AggregateResult> mockSlaByConfigResults;
    @TestVisible
    private static List<AggregateResult> mockSlaByAgentResults;
    @TestVisible
    private static List<AggregateResult> mockUtilisationResults;

    // ═══════════════════════════════════════════════════════════════════════════
    // Custom Setting Access — zero SOQL, hierarchy-aware
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @description Returns the effective lookback days from Analytics_Settings__c.
     *              Hierarchy resolution: User → Profile → Org Default → fallback.
     *              Zero SOQL — getInstance() is platform-cached.
     *
     * @return Configured lookback days (never null, never zero)
     */
    @TestVisible
    private static Integer getDefaultDays() {
        Analytics_Settings__c settings = Analytics_Settings__c.getInstance();
        if (settings != null && settings.Default_Lookback_Days__c != null
            && settings.Default_Lookback_Days__c > 0) {
            return settings.Default_Lookback_Days__c.intValue();
        }
        return FALLBACK_DAYS;
    }

    /**
     * @description Returns the effective max query rows from Analytics_Settings__c.
     *              Hierarchy resolution: User → Profile → Org Default → fallback.
     *              Zero SOQL — getInstance() is platform-cached.
     *
     * @return Configured max rows (never null, never zero)
     */
    @TestVisible
    private static Integer getMaxRows() {
        Analytics_Settings__c settings = Analytics_Settings__c.getInstance();
        if (settings != null && settings.Max_Query_Rows__c != null
            && settings.Max_Query_Rows__c > 0) {
            return settings.Max_Query_Rows__c.intValue();
        }
        return FALLBACK_MAX_ROWS;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Lens 1: Routing Velocity — avg duration trended by day
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @description Returns average Assignment_Duration_Ms__c per day for the
     *              last N days. Only includes successful assignments (Status = Success)
     *              where duration is populated.
     *
     *              Result fields: routedDay (Date), avgDurationMs (Decimal), routingCount (Integer)
     *
     * @param days Number of days to look back. When null/0, reads from
     *             Analytics_Settings__c.Default_Lookback_Days__c.
     * @return List of AggregateResult grouped by DAY_ONLY(Routed_At__c)
     */
    public static List<AggregateResult> getRoutingVelocity(Integer days) {
        if (Test.isRunningTest() && mockVelocityResults != null) {
            return mockVelocityResults;
        }

        Integer lookback = (days != null && days > 0) ? days : getDefaultDays();
        Integer maxRows = getMaxRows();
        String status = SUCCESS_STATUS;

        String soql = 'SELECT DAY_ONLY(Routed_At__c) routedDay, '
            + 'AVG(Assignment_Duration_Ms__c) avgDurationMs, '
            + 'COUNT(Id) routingCount '
            + 'FROM Routing_Log__c '
            + 'WHERE Status__c = :status '
            + 'AND Assignment_Duration_Ms__c != NULL '
            + 'AND Routed_At__c = LAST_N_DAYS:' + lookback + ' '
            + 'GROUP BY DAY_ONLY(Routed_At__c) '
            + 'ORDER BY DAY_ONLY(Routed_At__c) ASC '
            + 'LIMIT :maxRows';

        Map<String, Object> binds = new Map<String, Object>{
            'status' => status,
            'maxRows' => maxRows
        };

        return Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Lens 2: SLA Compliance — % Met vs Breached
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @description Returns SLA compliance counts grouped by Config_Developer_Name__c
     *              and SLA_Met__c. Only includes records where SLA was tracked
     *              (SLA_Met__c is not null).
     *
     *              Result fields: configName (String), slaStatus (String), slaCount (Integer)
     *
     * @param days Number of days to look back. When null/0, reads from
     *             Analytics_Settings__c.Default_Lookback_Days__c.
     * @return List of AggregateResult grouped by config + SLA status
     */
    public static List<AggregateResult> getSlaComplianceByConfig(Integer days) {
        if (Test.isRunningTest() && mockSlaByConfigResults != null) {
            return mockSlaByConfigResults;
        }

        Integer lookback = (days != null && days > 0) ? days : getDefaultDays();
        Integer maxRows = getMaxRows();

        String soql = 'SELECT Config_Developer_Name__c configName, '
            + 'SLA_Met__c slaStatus, '
            + 'COUNT(Id) slaCount '
            + 'FROM Routing_Log__c '
            + 'WHERE SLA_Met__c != NULL '
            + 'AND Routed_At__c = LAST_N_DAYS:' + lookback + ' '
            + 'GROUP BY Config_Developer_Name__c, SLA_Met__c '
            + 'ORDER BY Config_Developer_Name__c ASC '
            + 'LIMIT :maxRows';

        Map<String, Object> binds = new Map<String, Object>{
            'maxRows' => maxRows
        };

        return Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE);
    }

    /**
     * @description Returns SLA compliance counts grouped by Agent_Name__c
     *              and SLA_Met__c. Only includes records where SLA was tracked.
     *
     *              Result fields: agentName (String), slaStatus (String), slaCount (Integer)
     *
     * @param days Number of days to look back. When null/0, reads from
     *             Analytics_Settings__c.Default_Lookback_Days__c.
     * @return List of AggregateResult grouped by agent + SLA status
     */
    public static List<AggregateResult> getSlaComplianceByAgent(Integer days) {
        if (Test.isRunningTest() && mockSlaByAgentResults != null) {
            return mockSlaByAgentResults;
        }

        Integer lookback = (days != null && days > 0) ? days : getDefaultDays();
        Integer maxRows = getMaxRows();

        String soql = 'SELECT Agent_Name__c agentName, '
            + 'SLA_Met__c slaStatus, '
            + 'COUNT(Id) slaCount '
            + 'FROM Routing_Log__c '
            + 'WHERE SLA_Met__c != NULL '
            + 'AND Agent_Name__c != NULL '
            + 'AND Routed_At__c = LAST_N_DAYS:' + lookback + ' '
            + 'GROUP BY Agent_Name__c, SLA_Met__c '
            + 'ORDER BY Agent_Name__c ASC '
            + 'LIMIT :maxRows';

        Map<String, Object> binds = new Map<String, Object>{
            'maxRows' => maxRows
        };

        return Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Lens 3: Agent Utilisation — assigned count per agent per day
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @description Returns assignment counts per agent per day for the last N days.
     *              Only includes successful assignments where Agent_Name__c is populated.
     *              Consumer joins with Agent__c.Max_Capacity__c for utilisation %.
     *
     *              Result fields: agentName (String), routedDay (Date), assignedCount (Integer)
     *
     * @param days Number of days to look back. When null/0, reads from
     *             Analytics_Settings__c.Default_Lookback_Days__c.
     * @return List of AggregateResult grouped by agent + day
     */
    public static List<AggregateResult> getAgentUtilisation(Integer days) {
        if (Test.isRunningTest() && mockUtilisationResults != null) {
            return mockUtilisationResults;
        }

        Integer lookback = (days != null && days > 0) ? days : getDefaultDays();
        Integer maxRows = getMaxRows();
        String status = SUCCESS_STATUS;

        String soql = 'SELECT Agent_Name__c agentName, '
            + 'DAY_ONLY(Routed_At__c) routedDay, '
            + 'COUNT(Id) assignedCount '
            + 'FROM Routing_Log__c '
            + 'WHERE Status__c = :status '
            + 'AND Agent_Name__c != NULL '
            + 'AND Routed_At__c = LAST_N_DAYS:' + lookback + ' '
            + 'GROUP BY Agent_Name__c, DAY_ONLY(Routed_At__c) '
            + 'ORDER BY Agent_Name__c ASC, DAY_ONLY(Routed_At__c) ASC '
            + 'LIMIT :maxRows';

        Map<String, Object> binds = new Map<String, Object>{
            'status' => status,
            'maxRows' => maxRows
        };

        return Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE);
    }
}
