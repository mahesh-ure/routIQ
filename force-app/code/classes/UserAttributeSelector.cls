/**
 * @description Queries User field values needed by USER_ATTRIBUTE conditions.
 *
 *              Called once per routing transaction to pre-fetch all user fields
 *              referenced by active conditions. The resulting map is passed to
 *              ConditionBinder.resolveAll() for value resolution.
 *
 *              Cost: 1 SOQL (skipped entirely when no USER_ATTRIBUTE conditions exist).
 *
 * @group Selector
 */
public with sharing class UserAttributeSelector {

    @TestVisible
    private static Map<String, Object> mockAttributes;

    // ─── Public API ────────────────────────────────────────────────────────────

    /**
     * @description Queries the specified User fields for a given agent.
     *
     * @param userId       The agent's User record Id
     * @param fieldApiNames Set of User field API names to query (e.g. Department, Division)
     * @return Map of field API name → field value. Empty map if user not found.
     */
    public static Map<String, Object> getAttributes(
        Id userId,
        Set<String> fieldApiNames
    ) {
        if (Test.isRunningTest() && mockAttributes != null) {
            return mockAttributes;
        }

        if (userId == null || fieldApiNames == null || fieldApiNames.isEmpty()) {
            return new Map<String, Object>();
        }

        // Build field list — always include Id for completeness
        List<String> fields = new List<String>();
        Set<String> seen = new Set<String>();
        seen.add('id');
        fields.add('Id');

        for (String f : fieldApiNames) {
            String lower = f.toLowerCase();
            if (!seen.contains(lower)) {
                seen.add(lower);
                fields.add(f);
            }
        }

        String soql = 'SELECT ' + String.join(fields, ', ')
            + ' FROM User'
            + ' WHERE Id = :userId'
            + ' LIMIT 1';

        Map<String, Object> binds = new Map<String, Object>{
            'userId' => userId
        };

        List<SObject> results = Database.queryWithBinds(
            soql, binds, AccessLevel.USER_MODE
        );

        if (results.isEmpty()) {
            return new Map<String, Object>();
        }

        // Build field name → value map
        SObject userRecord = results[0];
        Map<String, Object> attributes = new Map<String, Object>();
        for (String field : fieldApiNames) {
            attributes.put(field, userRecord.get(field));
        }
        return attributes;
    }

    // ─── Helper ────────────────────────────────────────────────────────────────

    /**
     * @description Scans a list of conditions and collects all User field API names
     *              referenced by USER_ATTRIBUTE conditions. Used by the engine to
     *              determine which fields to pre-query before calling ConditionBinder.
     *
     * @param conditions List of conditions from one or more ConfigBundles
     * @return Set of User field API names. Empty set if no USER_ATTRIBUTE conditions.
     */
    public static Set<String> collectRequiredFields(
        List<Routing_Condition__mdt> conditions
    ) {
        Set<String> fields = new Set<String>();

        if (conditions == null) {
            return fields;
        }

        for (Routing_Condition__mdt cond : conditions) {
            if (cond.Value_Source__c == 'USER_ATTRIBUTE'
                && String.isNotBlank(cond.User_Attribute_Field__c)
            ) {
                fields.add(cond.User_Attribute_Field__c);
            }
        }

        return fields;
    }
}
