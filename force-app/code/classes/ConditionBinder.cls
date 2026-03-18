z/**
 * @description Resolves Routing_Condition__mdt records into a typed bind-variable map
 *              for use with Database.queryWithBinds().
 *
 *              For each condition at index i, produces a bind key "b{i}" mapped to either:
 *              • A typed List (for set operators: IN, NOT IN, INCLUDES, EXCLUDES, EQUALS, NOT_EQUALS)
 *              • A typed scalar (for comparison operators: LESS_THAN, GREATER_THAN, etc.)
 *
 *              Value resolution depends on Value_Source__c:
 *              • STATIC  — parses comma-delimited Values__c text field
 *              • USER_ATTRIBUTE — reads from the pre-queried userAttributes map,
 *                splits multi-select picklist values on semicolons
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
     * @param conditions     Sorted condition list from ConfigBundle
     * @param agentUserId    Id of the requesting agent (reserved for future attribute lookup)
     * @param userAttributes Pre-queried map of User field API name → field value
     * @return Bind map ready for Database.queryWithBinds()
     */
    public static Map<String, Object> resolveAll(
        List<Routing_Condition__mdt> conditions,
        Id agentUserId,
        Map<String, Object> userAttributes
    ) {
        Map<String, Object> bindMap = new Map<String, Object>();

        if (conditions == null || conditions.isEmpty()) {
            URE_Logger.debug('No conditions to resolve — empty bind map')
                .category(URE_Logger.Category.CONDITION_BIND)
                .inClass(CLS).inMethod('resolveAll')
                .log();
            return bindMap;
        }

        for (Integer i = 0; i < conditions.size(); i++) {
            Routing_Condition__mdt cond = conditions[i];
            String bindKey = 'b' + i;

            // Step 1 — Resolve raw string values from the configured source
            List<String> rawValues = resolveRawValues(cond, userAttributes);

            URE_Logger.debug('Condition b' + i
                    + ' | field=' + cond.Field_API_Name__c
                    + ' | op=' + cond.Operator__c
                    + ' | source=' + cond.Value_Source__c
                    + ' | type=' + cond.Value_Type__c
                    + ' | rawCount=' + rawValues.size())
                .category(URE_Logger.Category.CONDITION_BIND)
                .inClass(CLS).inMethod('resolveAll')
                .log();

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

        URE_Logger.debug('Bind resolution complete | conditions=' + conditions.size()
                + ' | bindKeys=' + bindMap.size())
            .category(URE_Logger.Category.CONDITION_BIND)
            .inClass(CLS).inMethod('resolveAll')
            .log();

        return bindMap;
    }

    // ─── Value Resolution ──────────────────────────────────────────────────────

    /**
     * @description Routes to the correct value source and returns raw string values.
     */
    private static List<String> resolveRawValues(
        Routing_Condition__mdt cond,
        Map<String, Object> userAttributes
    ) {
        if (cond.Value_Source__c == 'USER_ATTRIBUTE') {
            return resolveUserAttribute(cond, userAttributes);
        }
        // Default: STATIC
        return parseCommaDelimited(cond.Values__c);
    }

    /**
     * @description Splits a comma-delimited string into trimmed, non-blank values.
     */
    private static List<String> parseCommaDelimited(String value) {
        List<String> result = new List<String>();
        if (String.isBlank(value)) {
            return result;
        }
        for (String item : value.split(',')) {
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
            URE_Logger.warn('USER_ATTRIBUTE condition has no attributes map or field name'
                    + ' | field=' + cond.User_Attribute_Field__c)
                .category(URE_Logger.Category.CONDITION_BIND)
                .inClass(CLS).inMethod('resolveUserAttribute')
                .log();
            return result;
        }

        Object fieldValue = userAttributes.get(cond.User_Attribute_Field__c);
        if (fieldValue == null) {
            URE_Logger.debug('User attribute is null for field='
                    + cond.User_Attribute_Field__c + ' — will produce empty bind list')
                .category(URE_Logger.Category.CONDITION_BIND)
                .inClass(CLS).inMethod('resolveUserAttribute')
                .log();
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
                URE_Logger.warn('Skipping unparseable Decimal "' + val + '"')
                    .category(URE_Logger.Category.CONDITION_BIND)
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
                URE_Logger.warn('Skipping unparseable Date "' + val + '"')
                    .category(URE_Logger.Category.CONDITION_BIND)
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
                URE_Logger.warn('Skipping unparseable DateTime "' + val + '"')
                    .category(URE_Logger.Category.CONDITION_BIND)
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
            URE_Logger.warn('Unparseable Decimal scalar "' + val + '"')
                .category(URE_Logger.Category.CONDITION_BIND)
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
            URE_Logger.warn('Unparseable Date scalar "' + val + '"')
                .category(URE_Logger.Category.CONDITION_BIND)
                .inClass(CLS).inMethod('castToDate')
                .log();
            return null;
        }
    }

    private static DateTime castToDateTime(String val) {
        try {
            return DateTime.valueOf(val);
        } catch (Exception e) {
            URE_Logger.warn('Unparseable DateTime scalar "' + val + '"')
                .category(URE_Logger.Category.CONDITION_BIND)
                .inClass(CLS).inMethod('castToDateTime')
                .log();
            return null;
        }
    }
}
