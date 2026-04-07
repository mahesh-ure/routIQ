/**
 * @description Trace record for a single routing condition evaluation. Captures what
 *              the engine tested, what it expected, what it found, and whether the
 *              condition passed. Populated during condition matching regardless of
 *              dryRun -- callers use this for simulation display and debugging.
 *
 *              Created by RoutingEngine during condition evaluation (Layer 2/3).
 *              Consumed by:
 *              - RoutingResult.conditionTraces (returned to all callers)
 *              - Setup Wizard simulate step (Layer 7 -- dryRun display)
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

    // =========================================================================
    // LAYER 3 -- Enhanced condition trace fields
    // =========================================================================

    /**
     * @description Condition group number from Routing_Condition__mdt.Condition_Group__c.
     *              Null/0 = root-level AND condition. 1,2,3... = grouped (AND within group,
     *              OR between groups). Used by UI to visually group conditions.
     */
    @AuraEnabled
    global Decimal conditionGroup;

    /**
     * @description Value type of the condition (String, Number, Boolean, Date, DateTime).
     *              Sourced from Routing_Condition__mdt.Value_Type__c. Used by UI to
     *              format expected/actual values correctly.
     */
    @AuraEnabled
    global String valueType;

    /**
     * @description Sort order of the condition within its config. Sourced from
     *              Routing_Condition__mdt.Sort_Order__c. Allows UI to display conditions
     *              in the same order the admin configured them.
     */
    @AuraEnabled
    global Decimal sortOrder;

    /**
     * @description Source of the trace: 'CONDITION' for SOQL WHERE clause conditions,
     *              'SKILL_MATCH' for agent skill matching (Layer 4).
     */
    @AuraEnabled
    global String traceSource;

    // --- Private constructor -- use factory method ----------------------------

    @TestVisible
    private RoutingConditionTrace() {
    }

    // --- Factory -------------------------------------------------------------

    /**
     * @description Creates a fully populated trace record. Factory pattern enforces
     *              consistent construction and prevents partially initialized instances.
     *
     * @param fieldApiName  API name of the evaluated field
     * @param operator      Operator used (IN, EQUALS, GREATER_THAN, etc.)
     * @param expectedValue Expected value(s) from condition metadata
     * @param actualValue   Actual value from the work record (String-converted)
     * @param passed        Whether the condition was satisfied
     * @return Fully populated RoutingConditionTrace with traceSource='CONDITION'
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
        trace.traceSource = 'CONDITION';
        return trace;
    }

    /**
     * @description Layer 3: Creates a fully populated trace with condition group metadata.
     *              Used by RoutingEngine.buildConditionTraces() when condition metadata
     *              is available for richer trace output.
     *
     * @param fieldApiName   API name of the evaluated field
     * @param operator       Operator used (IN, EQUALS, GREATER_THAN, etc.)
     * @param expectedValue  Expected value(s) from condition metadata
     * @param actualValue    Actual value from the work record (String-converted)
     * @param passed         Whether the condition was satisfied
     * @param conditionGroup Condition group number (null/0=root, 1+= grouped)
     * @param valueType      Value type (String, Number, Boolean, Date, DateTime)
     * @param sortOrder      Condition sort order within the config
     * @return Fully populated RoutingConditionTrace with all metadata
     */
    global static RoutingConditionTrace createWithMetadata(
        String fieldApiName,
        String operator,
        String expectedValue,
        String actualValue,
        Boolean passed,
        Decimal conditionGroup,
        String valueType,
        Decimal sortOrder
    ) {
        RoutingConditionTrace trace = create(
            fieldApiName, operator, expectedValue, actualValue, passed
        );
        trace.conditionGroup = conditionGroup;
        trace.valueType = valueType;
        trace.sortOrder = sortOrder;
        return trace;
    }
}
