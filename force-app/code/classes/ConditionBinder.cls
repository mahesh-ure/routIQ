/**
 * @description Resolves Routing_Condition__mdt records into a typed bind-variable map
 *              for use with Database.queryWithBinds().
 *
 *              For each condition at index i, produces a bind key "b{i}" mapped to either:
 *              • A typed List (for set operators: IN, NOT IN, INCLUDES, EXCLUDES, EQUALS, NOT_EQUALS)
 *              • A typed scalar (for comparison operators: LESS_THAN, GREATER_THAN, etc.)
 *
 *              v2 change: USER_ATTRIBUTE value source removed entirely. All conditions
 *              are now STATIC only. Agent-specific filtering is handled by AgentMatcher
 *              using the capability-matching model.
 *
 *              Value parsing supports both comma and semicolon delimiters for consistency
 *              with Agent_Capability_Value__c.Values__c parsing.
 *
 *              Type casting is driven by Value_Type__c (String, Number, Boolean, Date, DateTime).
 *              Unparseable values are silently skipped — never throws on bad admin data.
 *
 * @group Worker
 */
public with sharing class ConditionBinder {

    private static final String CLS = 'ConditionBinder';

    private static final Set<String> SCALAR_OPERATORS = new Set<String>{
        'LESS_THAN', 'GREATER_THAN', 'LESS_OR_EQUAL', 'GREATER_OR_EQUAL'
    };

    // ─── Public API ────────────────────────────────────────────────────────────

    /**
     * @description Resolves all conditions into a single bind map keyed b0, b1, b2…
     *              Each value is typed to match Value_Type__c so Database.queryWithBinds()
     *              generates correct SOQL literals.
     *
     *              v2: Simplified signature — userAttributes parameter removed.
     *              All conditions are STATIC source only.
     *
     * @param conditions Sorted condition list from ConfigBundle
     * @return Bind map ready for Database.queryWithBinds()
     */
    public static Map<String, Object> resolveAll(
        List<Routing_Condition__mdt> conditions
    ) {
        Map<String, Object> bindMap = new Map<String, Object>();

        if (conditions == null || conditions.isEmpty()) {
            return bindMap;
        }

        for (Integer i = 0; i < conditions.size(); i++) {
            Routing_Condition__mdt cond = conditions[i];
            String bindKey = 'b' + i;

            // Step 1 — Parse STATIC values (comma and semicolon delimited)
            List<String> rawValues = parseDelimited(cond.Values__c);

            // Step 2 — Cast to the target type and store in bind map
            String valueType = (String.isNotBlank(cond.Value_Type__c))
                ? cond.Value_Type__c
                : 'String';

            if (SCALAR_OPERATORS.contains(cond.Operator__c)) {
                bindMap.put(bindKey, castScalar(rawValues, valueType));
            } else {
                bindMap.put(bindKey, castList(rawValues, valueType));
            }
        }

        return bindMap;
    }

    // ─── Value Parsing ──────────────────────────────────────────────────────

    /**
     * @description Splits a comma-and-semicolon-delimited string into trimmed,
     *              non-blank values. Supports both separators for consistency with
     *              Agent_Capability_Value__c parsing.
     */
    @TestVisible
    private static List<String> parseDelimited(String value) {
        List<String> result = new List<String>();
        if (String.isBlank(value)) {
            return result;
        }
        for (String item : value.split('[,;]')) {
            String trimmed = item.trim();
            if (String.isNotBlank(trimmed)) {
                result.add(trimmed);
            }
        }
        return result;
    }

    /**
     * @description Resolves a value from the pre-queried user attributes map.
     *              Multi-select picklist values (semicolon-delimited) are split
     *              into individual entries.
     *
     *              Returns empty list when the field is null or missing — this
     *              yields zero matches in an IN clause, which is the correct
     *              behavior (user lacks the required attribute).
     */
    private static List<String> resolveUserAttribute(
        Routing_Condition__mdt cond,
        Map<String, Object> userAttributes
    ) {
        List<String> result = new List<String>();

        if (userAttributes == null || String.isBlank(cond.User_Attribute_Field__c)) {
            Logger.warn('USER_ATTRIBUTE condition has no attributes map or field name'
                    + ' | field=' + cond.User_Attribute_Field__c)
                .category(Logger.Category.CONDITION_BIND)
                .inClass(CLS).inMethod('resolveUserAttribute')
                .log();
            return result;
        }

        Object fieldValue = userAttributes.get(cond.User_Attribute_Field__c);
        if (fieldValue == null) {
            return result;
        }

        String stringValue = String.valueOf(fieldValue);
        for (String item : stringValue.split(';')) {
            String trimmed = item.trim();
            if (String.isNotBlank(trimmed)) {
                result.add(trimmed);
            }
        }

        return result;
    }

    // ─── Type Casting — Lists ──────────────────────────────────────────────────

    /**
     * @description Casts raw string values into a properly typed List for set operators.
     *              Database.queryWithBinds() requires the runtime type of the list to match
     *              the SOQL field type (e.g. List<Decimal> for Number fields, not List<Object>).
     */
    private static Object castList(List<String> rawValues, String valueType) {
        switch on valueType {
            when 'Number' {
                return castToDecimalList(rawValues);
            }
            when 'Boolean' {
                return castToBooleanList(rawValues);
            }
            when 'Date' {
                return castToDateList(rawValues);
            }
            when 'DateTime' {
                return castToDateTimeList(rawValues);
            }
            when else {
                return rawValues;
            }
        }
    }

    private static List<Decimal> castToDecimalList(List<String> rawValues) {
        List<Decimal> result = new List<Decimal>();
        for (String val : rawValues) {
            try {
                result.add(Decimal.valueOf(val));
            } catch (Exception e) {
                Logger.warn('Skipping unparseable Decimal "' + val + '"')
                    .category(Logger.Category.CONDITION_BIND)
                    .inClass(CLS).inMethod('castToDecimalList')
                    .log();
            }
        }
        return result;
    }

    private static List<Boolean> castToBooleanList(List<String> rawValues) {
        List<Boolean> result = new List<Boolean>();
        for (String val : rawValues) {
            String lower = val.toLowerCase();
            if (lower == 'true') {
                result.add(true);
            } else if (lower == 'false') {
                result.add(false);
            }
        }
        return result;
    }

    private static List<Date> castToDateList(List<String> rawValues) {
        List<Date> result = new List<Date>();
        for (String val : rawValues) {
            try {
                result.add(Date.valueOf(val));
            } catch (Exception e) {
                Logger.warn('Skipping unparseable Date "' + val + '"')
                    .category(Logger.Category.CONDITION_BIND)
                    .inClass(CLS).inMethod('castToDateList')
                    .log();
            }
        }
        return result;
    }

    private static List<DateTime> castToDateTimeList(List<String> rawValues) {
        List<DateTime> result = new List<DateTime>();
        for (String val : rawValues) {
            try {
                result.add(DateTime.valueOf(val));
            } catch (Exception e) {
                Logger.warn('Skipping unparseable DateTime "' + val + '"')
                    .category(Logger.Category.CONDITION_BIND)
                    .inClass(CLS).inMethod('castToDateTimeList')
                    .log();
            }
        }
        return result;
    }

    // ─── Type Casting — Scalars ────────────────────────────────────────────────

    /**
     * @description Casts the first parseable raw value into a typed scalar for comparison
     *              operators (LESS_THAN, GREATER_THAN, LESS_OR_EQUAL, GREATER_OR_EQUAL).
     *              Returns null if no parseable value exists.
     */
    private static Object castScalar(List<String> rawValues, String valueType) {
        if (rawValues.isEmpty()) {
            return null;
        }

        // For scalar operators, only the first value is meaningful
        String firstValue = rawValues[0];

        switch on valueType {
            when 'Number' {
                return castToDecimal(firstValue);
            }
            when 'Boolean' {
                return castToBoolean(firstValue);
            }
            when 'Date' {
                return castToDate(firstValue);
            }
            when 'DateTime' {
                return castToDateTime(firstValue);
            }
            when else {
                return firstValue;
            }
        }
    }

    private static Decimal castToDecimal(String val) {
        try {
            return Decimal.valueOf(val);
        } catch (Exception e) {
            Logger.warn('Unparseable Decimal scalar "' + val + '"')
                .category(Logger.Category.CONDITION_BIND)
                .inClass(CLS).inMethod('castToDecimal')
                .log();
            return null;
        }
    }

    private static Boolean castToBoolean(String val) {
        String lower = val.toLowerCase();
        if (lower == 'true') {
            return true;
        }
        if (lower == 'false') {
            return false;
        }
        return null;
    }

    private static Date castToDate(String val) {
        try {
            return Date.valueOf(val);
        } catch (Exception e) {
            Logger.warn('Unparseable Date scalar "' + val + '"')
                .category(Logger.Category.CONDITION_BIND)
                .inClass(CLS).inMethod('castToDate')
                .log();
            return null;
        }
    }

    private static DateTime castToDateTime(String val) {
        try {
            return DateTime.valueOf(val);
        } catch (Exception e) {
            Logger.warn('Unparseable DateTime scalar "' + val + '"')
                .category(Logger.Category.CONDITION_BIND)
                .inClass(CLS).inMethod('castToDateTime')
                .log();
            return null;
        }
    }
}
