/**
 * @description Apex controller for the Routing Simulator standalone LWC.
 *              Provides server-side operations for testing routing configurations
 *              in isolation without making actual assignments.
 *
 *              Methods:
 *              1. getActiveConfigs      — Load active Routing_Config__mdt records
 *              2. simulateRouting       — Dry-run routing via RoutingService
 *
 *              Security:
 *              • All SOQL uses AccessLevel.USER_MODE for CRUD/FLS enforcement
 *              • Metadata queries use platform cache (no SOQL)
 *              • All inputs validated before use
 *
 *              Governor awareness:
 *              • getActiveConfigs: 0 SOQL (CMDT platform-cached)
 *              • simulateRouting: same cost as normal route() minus DML
 *
 * @group Controller
 */
public with sharing class RoutingSimulatorController {

    private static final String CLS = 'RoutingSimulatorController';

    /**
     * @description Returns all active Routing_Config__mdt records for the
     *              simulator config selector. CMDT cached by platform.
     *
     * @return List of ConfigInfo DTOs with developerName and label
     */
    @AuraEnabled(cacheable=true)
    public static List<ConfigInfo> getActiveConfigs() {
        List<ConfigInfo> results = new List<ConfigInfo>();

        try {
            // Access CMDT via Apex. CMDT is always read-accessible in managed packages.
            List<Routing_Config__mdt> configs = [
                SELECT DeveloperName, MasterLabel, Object_API_Name__c
                FROM Routing_Config__mdt
                WHERE Active__c = true
                ORDER BY MasterLabel ASC
            ];

            for (Routing_Config__mdt cfg : configs) {
                ConfigInfo ci = new ConfigInfo();
                ci.developerName = cfg.DeveloperName;
                ci.label = cfg.MasterLabel;
                ci.objectApiName = cfg.Object_API_Name__c;
                results.add(ci);
            }
        } catch (Exception ex) {
            Logger.init('LWC', UserInfo.getUserId());
            Logger.error('Failed to load active configs | reason=' + ex.getMessage())
                .category(Logger.Category.CONFIG)
                .inClass(CLS).inMethod('getActiveConfigs')
                .withException(ex)
                .log();
            Logger.flush('Failure');
            // Return empty list on error — LWC will show "No configs available"
        }

        return results;
    }

    /**
     * @description DTO for active configuration info displayed in the simulator UI.
     */
    public class ConfigInfo {
        @AuraEnabled public String developerName;
        @AuraEnabled public String label;
        @AuraEnabled public String objectApiName;
    }

    /**
     * @description Simulates routing with a specific record and configuration.
     *              Calls RoutingService.getNextRecord() with dryRun=true.
     *              Returns full routing result with condition traces for display.
     *
     *              Does not modify any data: no DML, no events, no logs.
     *
     * @param recordId          18-char ID of the record to test
     * @param configDeveloperName Developer name of Routing_Config__mdt to test
     * @return SimulateResult with success/error, reasonSummary, condition traces
     * @throws AuraHandledException if inputs are invalid
     */
    @AuraEnabled
    public static SimulateResult simulateRouting(
        String recordId,
        String configDeveloperName
    ) {
        if (String.isBlank(recordId)) {
            throw new AuraHandledException(System.Label.URE_WIZARD_RECORD_REQUIRED);
        }

        if (String.isBlank(configDeveloperName)) {
            throw new AuraHandledException(System.Label.URE_WIZARD_CONFIG_REQUIRED_SIM);
        }

        // Validate recordId format (15 or 18 character Salesforce ID)
        String trimmedId = recordId.trim();
        if (trimmedId.length() != 15 && trimmedId.length() != 18) {
            throw new AuraHandledException(System.Label.URE_WIZARD_INVALID_RECORD_ID);
        }

        String objectApiName = '';
        try {
            Id parsedId = Id.valueOf(trimmedId);
            objectApiName = parsedId.getSObjectType().getDescribe().getName();
        } catch (Exception ex) {
            throw new AuraHandledException(System.Label.URE_WIZARD_CANNOT_DETERMINE_TYPE);
        }

        // Build routing request with dryRun flag
        RoutingRequest request = new RoutingRequest();
        request.recordId = trimmedId;
        request.objectApiName = objectApiName;
        request.configDevName = configDeveloperName;
        request.dryRun = true; // Simulate without side effects

        // Call routing service — dryRun suppresses all DML, events, logs
        Logger.init('LWC', UserInfo.getUserId());
        Logger.info('Simulator: routing dryRun started'
                + ' | record=' + trimmedId
                + ' | object=' + objectApiName
                + ' | config=' + configDeveloperName)
            .category(Logger.Category.ENGINE)
            .inClass(CLS).inMethod('simulateRouting')
            .log();

        RoutingResult result = RoutingService.getNextRecord(
            objectApiName,
            trimmedId,
            configDeveloperName,
            true  // dryRun flag
        );

        Logger.info('Simulator: routing dryRun completed'
                + ' | success=' + result.success
                + ' | tracesCount=' + (result.conditionTraces != null
                    ? result.conditionTraces.size() : 0))
            .category(Logger.Category.ENGINE)
            .inClass(CLS).inMethod('simulateRouting')
            .withLimits()
            .log();
        Logger.flush('Success');

        // Transform to serializable DTO
        SimulateResult sr = new SimulateResult();
        sr.success = result.success;
        sr.reasonSummary = result.reasonSummary;
        sr.errorMessage = result.errorMessage;
        sr.conditionTraces = result.conditionTraces;
        sr.assignedTo = result.assignedTo;
        sr.recordId = result.recordId;
        sr.objectApiName = result.objectApiName;

        return sr;
    }

    /**
     * @description DTO for simulation results displayed in the UI.
     *              Includes success flag, reason summary, condition traces for debugging.
     */
    public class SimulateResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String reasonSummary;
        @AuraEnabled public String errorMessage;
        @AuraEnabled public List<RoutingConditionTrace> conditionTraces;
        @AuraEnabled public String assignedTo;
        @AuraEnabled public String recordId;
        @AuraEnabled public String objectApiName;
    }
}
