/**
 * @description Data Transfer Object for routing requests. Carries all inputs needed
 *              by the routing engine. Used as the input type for @InvocableMethod (Flow)
 *              and @RestResource (external systems).
 *
 *              For "Get Next" (agent-initiated): all fields may be blank — engine
 *              evaluates all active configs.
 *              For "Route this record" (Flow/Trigger): objectApiName + recordId required.
 *              For "Specific config": configDeveloperName targets one config.
 *
 * @group Entry
 */
global with sharing class RoutingRequest {

    @InvocableVariable(
        label='Object API Name'
        description='SObject API name to route (e.g. Case, Loan_Application__c). Required when recordId is provided.'
        required=false
    )
    global String objectApiName;

    @InvocableVariable(
        label='Record Id'
        description='18-character ID of a specific record to route. When provided, objectApiName is also required.'
        required=false
    )
    global String recordId;

    @InvocableVariable(
        label='Config Developer Name'
        description='DeveloperName of a specific Routing Config to use. When blank, engine evaluates all active configs.'
        required=false
    )
    global String configDeveloperName;

    @InvocableVariable(
        label='Context Data'
        description='Optional JSON payload for extensibility. Passed through to the engine without interpretation.'
        required=false
    )
    global String contextData;

    // ═══════════════════════════════════════════════════════════════════════════
    // P1 ADDITIONS — Layer 0 schema lockdown (declarations only, no logic)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @description When true, the engine runs full matching logic and populates
     *              RoutingResult (including conditionTraces and reasonSummary) but
     *              skips ALL side effects: no DML, no EventBus.publish(), no
     *              Routing_Log__c write. Used by the Setup Wizard simulate step
     *              and the P2 Simulator.
     *
     *              Not exposed as @InvocableVariable — simulation is not a Flow
     *              use case. Set programmatically from LWC/Apex only.
     */
    global Boolean dryRun;

    /**
     * @description When populated, the engine skips candidate ranking and assigns
     *              directly to the specified Agent__c record. Still validates that
     *              the agent exists and is not Offline. Used by the Supervisor
     *              Dashboard manual reassign feature (F3).
     *
     *              Not exposed as @InvocableVariable — manual override is a
     *              supervisor action, not a Flow use case.
     */
    global Id overrideAgentId;

    /**
     * @description Short-form config developer name for the Invocable Action
     *              (Layer 4, F4). When populated, targets a specific
     *              Routing_Config__mdt by DeveloperName. When null, the engine
     *              resolves the config by matching the record's SObject type.
     *
     *              Exists alongside configDeveloperName for backward compatibility.
     *              Layer 2 logic will coalesce: configDevName ?? configDeveloperName.
     */
    @InvocableVariable(
        label='Config Dev Name'
        description='DeveloperName of a specific Routing Config. Short-form alias for configDeveloperName. When blank, engine resolves by SObject type.'
        required=false
    )
    global String configDevName;

    /**
     * @description When true, marks this routing request as an escalation path.
     *              Reserved for P2 Escalation Engine — not used in P1.
     *              Declared now to avoid schema changes after Layer 1.
     */
    global Boolean escalation;

    /**
     * @description Validates structural correctness of this request. Does not perform
     *              schema validation (that belongs in the engine layer).
     * @return Empty list if valid. List of error strings if invalid.
     */
    global List<String> validate() {
        List<String> errors = new List<String>();

        // If recordId is provided, objectApiName is mandatory
        if (String.isNotBlank(this.recordId) && String.isBlank(this.objectApiName)) {
            errors.add('objectApiName is required when recordId is provided.');
        }

        // Validate recordId format when provided
        if (String.isNotBlank(this.recordId)) {
            String trimmedId = this.recordId.trim();
            if (trimmedId.length() != 15 && trimmedId.length() != 18) {
                errors.add('recordId must be a valid 15 or 18 character Salesforce ID.');
            }
        }

        // Validate objectApiName is not whitespace-only when provided
        if (this.objectApiName != null && String.isBlank(this.objectApiName)) {
            errors.add('objectApiName cannot be blank when provided.');
        }

        // Validate configDeveloperName is not whitespace-only when provided
        if (this.configDeveloperName != null && String.isBlank(this.configDeveloperName)) {
            errors.add('configDeveloperName cannot be blank when provided.');
        }

        return errors;
    }
}
