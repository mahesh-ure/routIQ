/**
 * @description Trace record for a single routing condition evaluation. Captures what
 *              the engine tested, what it expected, what it found, and whether the
 *              condition passed. Populated during condition matching regardless of
 *              dryRun — callers use this for simulation display and debugging.
 *
 *              Created by RoutingEngine during condition evaluation (Layer 2).
 *              Consumed by:
 *              - RoutingResult.conditionTraces (returned to all callers)
 *              - Setup Wizard simulate step (Layer 7 — dryRun display)
 *              - P2 Simulator (future)
 *
 *              Standalone class (not inner) because:
 *              - Global access required for managed package subscriber visibility
 *              - @AuraEnabled serialization to LWC requires top-level class
 *              - @InvocableVariable on inner classes is unsupported in Flow
 *
 * @group Entry
 */
global with sharing class RoutingConditionTrace {

    /**
     * @description API name of the field evaluated (e.g. Priority, Origin, Amount).
     *              Sourced from Routing_Condition__mdt.Field_API_Name__c.
     */
    @AuraEnabled
    global String fieldApiName;

    /**
     * @description Operator applied during evaluation (e.g. IN, NOT_IN, EQUALS,
     *              GREATER_THAN). Sourced from Routing_Condition__mdt.Operator__c.
     */
    @AuraEnabled
    global String operator;

    /**
     * @description Expected value(s) defined in the condition metadata.
     *              For set operators (IN, NOT_IN): comma-delimited list.
     *              For scalar operators (EQUALS, GREATER_THAN): single value.
     *              Sourced from Routing_Condition__mdt.Values__c.
     */
    @AuraEnabled
    global String expectedValue;

    /**
     * @description Actual value found on the work record at evaluation time.
     *              Converted to String for consistent display across all field types.
     *              Null-safe: blank string when field value is null.
     */
    @AuraEnabled
    global String actualValue;

    /**
     * @description True if the condition evaluated successfully (actual matched expected
     *              per the operator). False if the record did not satisfy this condition.
     */
    @AuraEnabled
    global Boolean passed;

    // ─── Private constructor — use factory method ────────────────────────────

    @TestVisible
    private RoutingConditionTrace() {
    }

    // ─── Factory ─────────────────────────────────────────────────────────────

    /**
     * @description Creates a fully populated trace record. Factory pattern enforces
     *              consistent construction and prevents partially initialized instances.
     *
     * @param fieldApiName  API name of the evaluated field
     * @param operator      Operator used (IN, EQUALS, GREATER_THAN, etc.)
     * @param expectedValue Expected value(s) from condition metadata
     * @param actualValue   Actual value from the work record (String-converted)
     * @param passed        Whether the condition was satisfied
     * @return Fully populated RoutingConditionTrace
     */
    global static RoutingConditionTrace create(
        String fieldApiName,
        String operator,
        String expectedValue,
        String actualValue,
        Boolean passed
    ) {
        RoutingConditionTrace trace = new RoutingConditionTrace();
        trace.fieldApiName = fieldApiName;
        trace.operator = operator;
        trace.expectedValue = expectedValue;
        trace.actualValue = (actualValue != null) ? actualValue : '';
        trace.passed = passed;
        return trace;
    }
}
