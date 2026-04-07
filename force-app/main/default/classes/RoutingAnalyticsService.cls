/**
 * @description Service layer for the Analytics Dashboard LWC (P2 Feature 1).
 *              Transforms AggregateResult data from RoutingAnalyticsSelector into
 *              serializable DTOs consumable by Lightning Web Components.
 *
 *              All methods are @AuraEnabled(cacheable=true) for wire service caching.
 *              This means the platform caches responses — subsequent LWC loads within
 *              the cache TTL cost zero Apex execution and zero SOQL.
 *
 *              Security: with sharing enforced. All downstream queries use
 *              AccessLevel.USER_MODE for FLS. No additional stripInaccessible needed.
 *
 *              Governor cost per full dashboard load: 4 SOQL (one per lens query).
 *
 * @group Service
 */
public with sharing class RoutingAnalyticsService {

    // ═══════════════════════════════════════════════════════════════════════════
    // Configuration — expose Custom Setting values to LWC
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @description Returns the configured default lookback days from
     *              Analytics_Settings__c. Called once by the LWC on init so
     *              the wire calls use the admin-configured value, not a
     *              hardcoded JS constant.
     *
     *              Zero SOQL — getInstance() is platform-cached.
     *
     * @return Configured lookback days (falls back to 30 if not set)
     */
    @AuraEnabled(cacheable=true)
    public static Integer getDefaultLookbackDays() {
        Analytics_Settings__c settings = Analytics_Settings__c.getInstance();
        if (settings != null && settings.Default_Lookback_Days__c != null
            && settings.Default_Lookback_Days__c > 0) {
            return settings.Default_Lookback_Days__c.intValue();
        }
        return 30; // Compile-time fallback if Custom Setting not yet created
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Lens 1: Routing Velocity
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @description Returns daily routing velocity (avg duration + count) for the
     *              last N days. Used by the velocity trend chart in the dashboard.
     *
     * @param days Number of days to look back (default 30)
     * @return List of VelocityDataPoint ordered by date ascending
     */
    @AuraEnabled(cacheable=true)
    public static List<VelocityDataPoint> getRoutingVelocity(Integer days) {
        List<AggregateResult> results =
            RoutingAnalyticsSelector.getRoutingVelocity(days);

        List<VelocityDataPoint> dataPoints = new List<VelocityDataPoint>();
        for (AggregateResult ar : results) {
            VelocityDataPoint dp = new VelocityDataPoint();
            dp.routedDay = (Date) ar.get('routedDay');
            dp.avgDurationMs = ar.get('avgDurationMs') != null
                ? ((Decimal) ar.get('avgDurationMs')).setScale(0)
                : 0;
            dp.routingCount = ar.get('routingCount') != null
                ? (Integer) ar.get('routingCount')
                : 0;
            dataPoints.add(dp);
        }
        return dataPoints;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Lens 2: SLA Compliance
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @description Returns SLA compliance data grouped by config and by agent.
     *              Computes compliance rate (% Met) for each grouping.
     *
     * @param days Number of days to look back (default 30)
     * @return SlaComplianceData containing byConfig and byAgent breakdowns
     */
    @AuraEnabled(cacheable=true)
    public static SlaComplianceData getSlaCompliance(Integer days) {
        SlaComplianceData data = new SlaComplianceData();

        // ── By Config ───────────────────────────────────────────────────
        List<AggregateResult> configResults =
            RoutingAnalyticsSelector.getSlaComplianceByConfig(days);
        data.byConfig = buildSlaBreakdown(configResults, 'configName');

        // ── By Agent ────────────────────────────────────────────────────
        List<AggregateResult> agentResults =
            RoutingAnalyticsSelector.getSlaComplianceByAgent(days);
        data.byAgent = buildSlaBreakdown(agentResults, 'agentName');

        return data;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Lens 3: Agent Utilisation
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @description Returns daily assignment counts per agent for the last N days.
     *              The LWC pairs this with Agent__c.Max_Capacity__c (queried
     *              separately via LDS) to compute utilisation percentages.
     *
     * @param days Number of days to look back (default 30)
     * @return List of AgentDailyUtilisation ordered by agent then date
     */
    @AuraEnabled(cacheable=true)
    public static List<AgentDailyUtilisation> getAgentUtilisation(Integer days) {
        List<AggregateResult> results =
            RoutingAnalyticsSelector.getAgentUtilisation(days);

        List<AgentDailyUtilisation> dataPoints =
            new List<AgentDailyUtilisation>();
        for (AggregateResult ar : results) {
            AgentDailyUtilisation dp = new AgentDailyUtilisation();
            dp.agentName = (String) ar.get('agentName');
            dp.routedDay = (Date) ar.get('routedDay');
            dp.assignedCount = ar.get('assignedCount') != null
                ? (Integer) ar.get('assignedCount')
                : 0;
            dataPoints.add(dp);
        }
        return dataPoints;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Private Helpers
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @description Builds SLA breakdown from aggregate results. Groups by the
     *              specified dimension (config name or agent name) and computes
     *              met/breached counts + compliance rate.
     */
    private static List<SlaBreakdown> buildSlaBreakdown(
        List<AggregateResult> results, String groupField
    ) {
        // Accumulate counts per group
        Map<String, Integer> metCounts = new Map<String, Integer>();
        Map<String, Integer> breachedCounts = new Map<String, Integer>();
        List<String> orderedKeys = new List<String>();

        for (AggregateResult ar : results) {
            String groupKey = (String) ar.get(groupField);
            String slaStatus = (String) ar.get('slaStatus');
            Integer count = ar.get('slaCount') != null
                ? (Integer) ar.get('slaCount')
                : 0;

            if (!metCounts.containsKey(groupKey)) {
                metCounts.put(groupKey, 0);
                breachedCounts.put(groupKey, 0);
                orderedKeys.add(groupKey);
            }

            if (slaStatus == 'Met') {
                metCounts.put(groupKey, metCounts.get(groupKey) + count);
            } else if (slaStatus == 'Breached') {
                breachedCounts.put(groupKey, breachedCounts.get(groupKey) + count);
            }
        }

        // Build DTOs
        List<SlaBreakdown> breakdowns = new List<SlaBreakdown>();
        for (String key : orderedKeys) {
            SlaBreakdown bd = new SlaBreakdown();
            bd.groupName = key;
            bd.metCount = metCounts.get(key);
            bd.breachedCount = breachedCounts.get(key);
            Integer total = bd.metCount + bd.breachedCount;
            bd.complianceRate = (total > 0)
                ? ((Decimal) bd.metCount / total * 100).setScale(1)
                : 0;
            breakdowns.add(bd);
        }
        return breakdowns;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DTOs — @AuraEnabled properties for LWC wire serialization
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @description Daily routing velocity data point.
     */
    public class VelocityDataPoint {
        @AuraEnabled public Date routedDay;
        @AuraEnabled public Decimal avgDurationMs;
        @AuraEnabled public Integer routingCount;
    }

    /**
     * @description Container for SLA compliance data with two dimensions.
     */
    public class SlaComplianceData {
        @AuraEnabled public List<SlaBreakdown> byConfig;
        @AuraEnabled public List<SlaBreakdown> byAgent;
    }

    /**
     * @description SLA compliance breakdown for a single group (config or agent).
     */
    public class SlaBreakdown {
        @AuraEnabled public String groupName;
        @AuraEnabled public Integer metCount;
        @AuraEnabled public Integer breachedCount;
        @AuraEnabled public Decimal complianceRate;
    }

    /**
     * @description Daily assignment count for a single agent.
     */
    public class AgentDailyUtilisation {
        @AuraEnabled public String agentName;
        @AuraEnabled public Date routedDay;
        @AuraEnabled public Integer assignedCount;
    }
}
