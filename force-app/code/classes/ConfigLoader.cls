/**
 * @description Reads all routing CMDT types via RoutingConfigSelector, filters
 *              for active records, groups conditions, priorities, and v2 match
 *              conditions by parent config, and returns a sorted List<ConfigBundle>.
 *
 *              Called ONCE per transaction by RoutingEngine. The returned list is the
 *              engine's single source of truth for all routing configuration.
 *
 *              v2 additions:
 *              • Loads Agent_Match_Condition__mdt and groups by parent config
 *              • Includes match conditions in ConfigBundle constructor
 *
 *              Cost: zero SOQL (CMDT.getAll() is platform-cached), minimal CPU
 *              (small CMDT collections, one pass each for grouping).
 *
 * @group Worker
 */
public with sharing class ConfigLoader {

    private static final String CLS = 'ConfigLoader';

    /**
     * @description Loads all active routing configurations with their active conditions,
     *              priority sort specifications, and v2 agent match conditions.
     *
     * @return Sorted list of ConfigBundles. Empty list if no active configs exist.
     */
    public static List<ConfigBundle> loadActive() {

        // Step 1 — Read all CMDT (zero SOQL, platform-cached)
        Map<String, Routing_Config__mdt> allConfigs =
            RoutingConfigSelector.getAllConfigs();
        Map<String, Routing_Condition__mdt> allConditions =
            RoutingConfigSelector.getAllConditions();
        Map<String, Routing_Priority__mdt> allPriorities =
            RoutingConfigSelector.getAllPriorities();
        Map<String, Agent_Match_Condition__mdt> allMatchConditions =
            RoutingConfigSelector.getAllMatchConditions();

        URE_Logger.debug('CMDT loaded | configs=' + allConfigs.size()
                + ' | conditions=' + allConditions.size()
                + ' | priorities=' + allPriorities.size()
                + ' | matchConditions=' + allMatchConditions.size())
            .category(URE_Logger.Category.CONFIG)
            .inClass(CLS).inMethod('loadActive')
            .log();

        // Step 2 — Build reverse map: configId → DeveloperName
        Map<Id, String> configIdToDevName = new Map<Id, String>();
        for (Routing_Config__mdt cfg : allConfigs.values()) {
            configIdToDevName.put(cfg.Id, cfg.DeveloperName);
        }

        // Step 3 — Group ACTIVE conditions by parent config DeveloperName
        Map<String, List<Routing_Condition__mdt>> conditionsByConfig =
            new Map<String, List<Routing_Condition__mdt>>();

        for (Routing_Condition__mdt cond : allConditions.values()) {
            if (cond.Is_Active__c != true) {
                continue;
            }

            String parentDevName = configIdToDevName.get(cond.Routing_Config__c);
            if (parentDevName == null) {
                URE_Logger.debug('Orphan condition skipped: ' + cond.DeveloperName)
                    .category(URE_Logger.Category.CONFIG)
                    .inClass(CLS).inMethod('loadActive')
                    .log();
                continue;
            }

            if (!conditionsByConfig.containsKey(parentDevName)) {
                conditionsByConfig.put(
                    parentDevName,
                    new List<Routing_Condition__mdt>()
                );
            }
            conditionsByConfig.get(parentDevName).add(cond);
        }

        // Step 4 — Group priorities by parent config DeveloperName
        Map<String, List<Routing_Priority__mdt>> prioritiesByConfig =
            new Map<String, List<Routing_Priority__mdt>>();

        for (Routing_Priority__mdt pri : allPriorities.values()) {
            String parentDevName = configIdToDevName.get(pri.Routing_Config__c);
            if (parentDevName == null) {
                continue;
            }

            if (!prioritiesByConfig.containsKey(parentDevName)) {
                prioritiesByConfig.put(
                    parentDevName,
                    new List<Routing_Priority__mdt>()
                );
            }
            prioritiesByConfig.get(parentDevName).add(pri);
        }

        // Step 5 — Group match conditions by parent config DeveloperName (v2)
        Map<String, List<Agent_Match_Condition__mdt>> matchConditionsByConfig =
            new Map<String, List<Agent_Match_Condition__mdt>>();

        for (Agent_Match_Condition__mdt mc : allMatchConditions.values()) {
            String parentDevName = configIdToDevName.get(mc.Routing_Config__c);
            if (parentDevName == null) {
                URE_Logger.debug('Orphan match condition skipped: ' + mc.DeveloperName)
                    .category(URE_Logger.Category.CONFIG)
                    .inClass(CLS).inMethod('loadActive')
                    .log();
                continue;
            }

            if (!matchConditionsByConfig.containsKey(parentDevName)) {
                matchConditionsByConfig.put(
                    parentDevName,
                    new List<Agent_Match_Condition__mdt>()
                );
            }
            matchConditionsByConfig.get(parentDevName).add(mc);
        }

        // Step 6 — Build one ConfigBundle per ACTIVE config
        List<ConfigBundle> bundles = new List<ConfigBundle>();
        Integer skippedInactive = 0;

        for (Routing_Config__mdt cfg : allConfigs.values()) {
            if (cfg.Active__c != true) {
                skippedInactive++;
                continue;
            }

            String devName = cfg.DeveloperName;

            List<Routing_Condition__mdt> conditions = conditionsByConfig.containsKey(devName)
                ? conditionsByConfig.get(devName)
                : new List<Routing_Condition__mdt>();

            List<Routing_Priority__mdt> priorities = prioritiesByConfig.containsKey(devName)
                ? prioritiesByConfig.get(devName)
                : new List<Routing_Priority__mdt>();

            List<Agent_Match_Condition__mdt> matchConds = matchConditionsByConfig.containsKey(devName)
                ? matchConditionsByConfig.get(devName)
                : new List<Agent_Match_Condition__mdt>();

            bundles.add(new ConfigBundle(cfg, conditions, priorities, matchConds));
        }

        // Step 7 — Sort bundles by Priority_Weight__c ascending
        bundles.sort();

        URE_Logger.info('Config load complete | activeBundles=' + bundles.size()
                + ' | skippedInactive=' + skippedInactive)
            .category(URE_Logger.Category.CONFIG)
            .inClass(CLS).inMethod('loadActive')
            .log();

        return bundles;
    }
}
