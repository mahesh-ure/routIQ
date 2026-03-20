/**
 * @description Selector for all routing Custom Metadata Types. All reads use
 *              CMDT.getAll() which is platform-cached and consumes zero SOQL queries.
 *
 *              This is the ONLY class that reads routing CMDT. All other classes receive
 *              CMDT data via ConfigBundle.
 *
 *              v2: Added Agent_Capability__mdt and Agent_Match_Condition__mdt selectors
 *              for the capability-matching model.
 *
 *              Test isolation: each getter has a @TestVisible mock override. Tests inject
 *              mock CMDT records without deploying metadata or using SOQL.
 *
 * @group Selector
 */
public with sharing class RoutingConfigSelector {

    @TestVisible
    private static Map<String, Routing_Config__mdt> mockConfigs;

    @TestVisible
    private static Map<String, Routing_Condition__mdt> mockConditions;

    @TestVisible
    private static Map<String, Routing_Priority__mdt> mockPriorities;

    @TestVisible
    private static Map<String, Agent_Capability__mdt> mockCapabilities;

    @TestVisible
    private static Map<String, Agent_Match_Condition__mdt> mockMatchConditions;

    /**
     * @description Returns all Routing Config records. Zero SOQL — platform-cached.
     * @return Map keyed by DeveloperName
     */
    public static Map<String, Routing_Config__mdt> getAllConfigs() {
        if (Test.isRunningTest() && mockConfigs != null) {
            return mockConfigs;
        }
        return Routing_Config__mdt.getAll();
    }

    /**
     * @description Returns all Routing Condition records. Zero SOQL — platform-cached.
     * @return Map keyed by DeveloperName
     */
    public static Map<String, Routing_Condition__mdt> getAllConditions() {
        if (Test.isRunningTest() && mockConditions != null) {
            return mockConditions;
        }
        return Routing_Condition__mdt.getAll();
    }

    /**
     * @description Returns all Routing Priority records. Zero SOQL — platform-cached.
     * @return Map keyed by DeveloperName
     */
    public static Map<String, Routing_Priority__mdt> getAllPriorities() {
        if (Test.isRunningTest() && mockPriorities != null) {
            return mockPriorities;
        }
        return Routing_Priority__mdt.getAll();
    }

    /**
     * @description Returns all Agent Capability records. Zero SOQL — platform-cached.
     *              v2 addition for capability-matching model.
     * @return Map keyed by DeveloperName
     */
    public static Map<String, Agent_Capability__mdt> getAllCapabilities() {
        if (Test.isRunningTest() && mockCapabilities != null) {
            return mockCapabilities;
        }
        return Agent_Capability__mdt.getAll();
    }

    /**
     * @description Returns all Agent Match Condition records. Zero SOQL — platform-cached.
     *              v2 addition for capability-matching model.
     * @return Map keyed by DeveloperName
     */
    public static Map<String, Agent_Match_Condition__mdt> getAllMatchConditions() {
        if (Test.isRunningTest() && mockMatchConditions != null) {
            return mockMatchConditions;
        }
        return Agent_Match_Condition__mdt.getAll();
    }
}
