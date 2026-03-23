/**
 * @description Selector for all routing Custom Metadata Types. All reads use
 *              CMDT.getAll() which is platform-cached and consumes zero SOQL queries.
 *
 *              This is the ONLY class that reads routing CMDT. All other classes receive
 *              CMDT data via ConfigBundle.
 *
 *              v6: Renamed Agent_Capability__mdt to Agent_Skill__mdt and
 *              Agent_Match_Condition__mdt to Routing_Skill_Mapping__mdt for
 *              admin-intuitive naming as part of the Skill Bundle refactor.
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
    private static Map<String, Agent_Skill__mdt> mockSkills;

    @TestVisible
    private static Map<String, Routing_Skill_Mapping__mdt> mockSkillMappings;

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
     * @description Returns all Agent Skill dimension records. Zero SOQL — platform-cached.
     *              v6: Renamed from getAllCapabilities() — Agent_Capability__mdt is now Agent_Skill__mdt.
     * @return Map keyed by DeveloperName
     */
    public static Map<String, Agent_Skill__mdt> getAllSkills() {
        if (Test.isRunningTest() && mockSkills != null) {
            return mockSkills;
        }
        return Agent_Skill__mdt.getAll();
    }

    /**
     * @description Returns all Routing Skill Mapping records. Zero SOQL — platform-cached.
     *              v6: Renamed from getAllMatchConditions() — Agent_Match_Condition__mdt is
     *              now Routing_Skill_Mapping__mdt.
     * @return Map keyed by DeveloperName
     */
    public static Map<String, Routing_Skill_Mapping__mdt> getAllSkillMappings() {
        if (Test.isRunningTest() && mockSkillMappings != null) {
            return mockSkillMappings;
        }
        return Routing_Skill_Mapping__mdt.getAll();
    }
}
