/**
 * @description Selector for all three routing Custom Metadata Types. All reads use
 *              CMDT.getAll() which is platform-cached and consumes zero SOQL queries.
 *
 *              This is the ONLY class that reads routing CMDT. All other classes receive
 *              CMDT data via ConfigBundle.
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
}
