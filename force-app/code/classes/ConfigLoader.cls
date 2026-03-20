/**
 * @description Reads all three routing CMDT types via RoutingConfigSelector, filters
 *              for active records, groups conditions and priorities by parent config,
 *              and returns a sorted List<ConfigBundle>.
 *
 *              Called ONCE per transaction by RoutingEngine. The returned list is the
 *              engine's single source of truth for all routing configuration.
 *
 *              Cost: zero SOQL (CMDT.getAll() is platform-cached), minimal CPU
 *              (small CMDT collections, one pass each for grouping).
 *
 * @group Worker
 */
public with sharing class ConfigLoader {

    private static final String CLS = 'ConfigLoader';

    /**
     * @description Loads all active routing configurations with their active conditions
     *              and priority sort specifications.
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

        Logger.debug('CMDT loaded | configs=' + allConfigs.size()
                + ' | conditions=' + allConditions.size()
                + ' | priorities=' + allPriorities.size())
            .category(Logger.Category.CONFIG)
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
                Logger.debug('Orphan condition skipped: ' + cond.DeveloperName)
                    .category(Logger.Category.CONFIG)
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

        // Step 5 — Build one ConfigBundle per ACTIVE config
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

            bundles.add(new ConfigBundle(cfg, conditions, priorities));
        }

        // Step 6 — Sort bundles by Priority_Weight__c ascending
        bundles.sort();

        Logger.info('Config load complete | activeBundles=' + bundles.size()
                + ' | skippedInactive=' + skippedInactive)
            .category(Logger.Category.CONFIG)
            .inClass(CLS).inMethod('loadActive')
            .log();

        return bundles;
    }
}
