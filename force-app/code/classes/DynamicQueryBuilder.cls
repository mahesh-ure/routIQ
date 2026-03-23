/**
 * @description Assembles a bind-variable-only dynamic SOQL query from a ConfigBundle
 *              and the typed bind map produced by ConditionBinder.
 *
 *              Security model:
 *              • Zero string interpolation of user/admin data into SOQL — all values
 *                flow through Database.queryWithBinds() bind variables.
 *              • Field and object API names come from CMDT (admin-configured, trusted).
 *              • The caller executes the query with AccessLevel.USER_MODE for FLS enforcement.
 *
 *              SOQL structure (ungrouped — backward compatible):
 *                SELECT  {Id, ownerField, selectFields}
 *                FROM    {objectApiName}
 *                WHERE   {condition clauses AND-joined}
 *                        [AND RecordType.DeveloperName IN :rtFilter]
 *                        [AND Id = :recId]
 *                ORDER BY {priority sort specs}
 *                LIMIT   {candidateLimit}
 *
 *              SOQL structure (grouped — Condition_Group__c populated):
 *                SELECT  ...
 *                FROM    {objectApiName}
 *                WHERE   {root conditions AND-joined}
 *                        AND (
 *                          ({group 1 conditions AND-joined})
 *                          OR ({group 2 conditions AND-joined})
 *                        )
 *                        [AND RecordType.DeveloperName IN :rtFilter]
 *                        [AND Id = :recId]
 *                ORDER BY ...
 *                LIMIT   ...
 *
 *              Grouping model:
 *              • Condition_Group__c = null  → root-level AND (global filter)
 *              • Condition_Group__c = 1,2…  → AND within group, OR between groups
 *              • Bind keys (b0, b1…) are always sequential across ALL conditions
 *                regardless of grouping — ConditionBinder assigns by list index.
 *
 * @group Worker
 */
public with sharing class DynamicQueryBuilder {

    private static final String CLS = 'DynamicQueryBuilder';

    // ─── Public API ────────────────────────────────────────────────────────────

    /**
     * @description Builds a QuerySpec for all candidates matching a config's conditions.
     * @param bundle  The routing configuration bundle
     * @param bindMap Typed bind map from ConditionBinder.resolveAll()
     * @return QuerySpec ready for Database.queryWithBinds()
     */
    public static QuerySpec build(ConfigBundle bundle, Map<String, Object> bindMap) {
        return build(bundle, bindMap, null);
    }

    /**
     * @description Builds a QuerySpec, optionally scoped to a single record.
     * @param bundle   The routing configuration bundle
     * @param bindMap  Typed bind map from ConditionBinder.resolveAll()
     * @param recordId Optional 15/18-char record ID to scope query to one record
     * @return QuerySpec ready for Database.queryWithBinds()
     */
    public static QuerySpec build(
        ConfigBundle bundle,
        Map<String, Object> bindMap,
        String recordId
    ) {
        // Clone to avoid mutating caller's bind map
        Map<String, Object> binds = new Map<String, Object>(bindMap);

        String selectClause  = buildSelect(bundle);
        String fromClause    = bundle.objectApiName;
        String whereClause   = buildWhere(bundle, binds, recordId);
        String orderByClause = buildOrderBy(bundle);
        Integer limitValue   = bundle.candidateLimit;

        // ── Assemble SOQL ──────────────────────────────────────────────────
        String soql = 'SELECT ' + selectClause + ' FROM ' + fromClause;

        if (String.isNotBlank(whereClause)) {
            soql += ' WHERE ' + whereClause;
        }

        if (String.isNotBlank(orderByClause)) {
            soql += ' ORDER BY ' + orderByClause;
        }

        soql += ' LIMIT ' + limitValue;

        // ── Log full SOQL query with resolved bind values ─────────────
        Logger.info('SOQL query | ' + soql + ' | ' + formatBindValues(binds))
            .category(Logger.Category.QUERY_BUILD)
            .inClass(CLS).inMethod('build')
            .forConfig(bundle.developerName)
            .forObject(bundle.objectApiName)
            .log();

        return new QuerySpec(soql, binds, bundle.objectApiName);
    }

    // ─── SELECT ────────────────────────────────────────────────────────────────

    /**
     * @description Builds a deduplicated, order-preserving SELECT field list.
     *              Always includes Id first, then ownerFieldApiName, then selectFields.
     */
    private static String buildSelect(ConfigBundle bundle) {
        List<String> fields = new List<String>();
        Set<String> seen = new Set<String>();

        addField(fields, seen, 'Id');

        if (String.isNotBlank(bundle.ownerFieldApiName)) {
            addField(fields, seen, bundle.ownerFieldApiName);
        }

        if (bundle.selectFields != null) {
            for (String f : bundle.selectFields) {
                addField(fields, seen, f);
            }
        }

        return String.join(fields, ', ');
    }

    /**
     * @description Adds a field to the list if not already present (case-insensitive).
     */
    private static void addField(List<String> fields, Set<String> seen, String field) {
        String lower = field.toLowerCase();
        if (!seen.contains(lower)) {
            seen.add(lower);
            fields.add(field);
        }
    }

    // ─── WHERE ─────────────────────────────────────────────────────────────────

    /**
     * @description Builds the WHERE clause with support for condition grouping.
     *
     *              Grouping model (driven by Condition_Group__c on each condition):
     *              • null/0 → root-level condition, AND-joined globally
     *              • 1,2,3… → grouped condition, AND-joined within group,
     *                          OR-joined between groups
     *
     *              Final structure:
     *                root_cond_1 AND root_cond_2
     *                AND (
     *                  (group1_cond1 AND group1_cond2)
     *                  OR (group2_cond1 AND group2_cond2)
     *                )
     *                AND RecordType.DeveloperName IN :rtFilter
     *                AND Id = :recId
     *
     *              Backward compatible: when no conditions have Condition_Group__c
     *              set, all conditions are root-level → pure AND (identical to v1).
     *
     *              Bind keys (b0, b1…) are sequential by condition list index —
     *              same order as ConditionBinder.resolveAll(). Grouping only
     *              changes WHERE clause assembly, not bind key assignment.
     */
    private static String buildWhere(
        ConfigBundle bundle,
        Map<String, Object> binds,
        String recordId
    ) {
        // ── Separate root vs grouped conditions ─────────────────────────
        List<String> rootClauses = new List<String>();
        Map<Decimal, List<String>> groupClauses =
            new Map<Decimal, List<String>>();
        List<Decimal> groupKeys = new List<Decimal>();

        for (Integer i = 0; i < bundle.conditions.size(); i++) {
            Routing_Condition__mdt cond = bundle.conditions[i];
            String bindKey = 'b' + i;
            String clause = buildConditionClause(cond, bindKey);

            Decimal groupNum = cond.Condition_Group__c;

            if (groupNum == null || groupNum == 0) {
                // Root-level: AND-joined globally
                rootClauses.add(clause);
            } else {
                // Grouped: AND within group, OR between groups
                if (!groupClauses.containsKey(groupNum)) {
                    groupClauses.put(groupNum, new List<String>());
                    groupKeys.add(groupNum);
                }
                groupClauses.get(groupNum).add(clause);
            }
        }

        // ── Record type filter (root level) ─────────────────────────────
        if (!bundle.recordTypeDevNames.isEmpty()) {
            binds.put('rtFilter', bundle.recordTypeDevNames);
            rootClauses.add('RecordType.DeveloperName IN :rtFilter');
        }

        // ── Single-record scope (root level) ────────────────────────────
        if (String.isNotBlank(recordId)) {
            binds.put('recId', recordId);
            rootClauses.add('Id = :recId');
        }

        // ── Assemble final WHERE ────────────────────────────────────────
        List<String> allParts = new List<String>();

        // Root conditions first (AND-joined)
        allParts.addAll(rootClauses);

        // Grouped conditions (OR between groups, AND within)
        if (!groupClauses.isEmpty()) {
            groupKeys.sort(); // Deterministic group order: 1, 2, 3…

            List<String> orParts = new List<String>();
            for (Decimal key : groupKeys) {
                List<String> withinGroup = groupClauses.get(key);
                if (withinGroup.size() == 1) {
                    orParts.add(withinGroup[0]);
                } else {
                    orParts.add('(' + String.join(withinGroup, ' AND ') + ')');
                }
            }

            // Single group: no OR wrapper needed — just add as AND
            // Multiple groups: wrap in parentheses with OR
            if (orParts.size() == 1) {
                allParts.add(orParts[0]);
            } else {
                allParts.add('(' + String.join(orParts, ' OR ') + ')');
            }
        }

        return String.join(allParts, ' AND ');
    }

    /**
     * @description Translates one Routing_Condition__mdt into a SOQL clause fragment.
     *
     *              Operator mapping:
     *              • IN / EQUALS        → field IN :bN          (list bind)
     *              • NOT_IN / NOT_EQUALS → field NOT IN :bN     (list bind)
     *              • INCLUDES           → field INCLUDES (:bN)  (multi-select picklist)
     *              • EXCLUDES           → field EXCLUDES (:bN)  (multi-select picklist)
     *              • LESS_THAN          → field < :bN           (scalar bind)
     *              • GREATER_THAN       → field > :bN           (scalar bind)
     *              • LESS_OR_EQUAL      → field <= :bN          (scalar bind)
     *              • GREATER_OR_EQUAL   → field >= :bN          (scalar bind)
     */
    private static String buildConditionClause(
        Routing_Condition__mdt cond,
        String bindKey
    ) {
        String field = cond.Field_API_Name__c;
        String op = cond.Operator__c;

        switch on op {
            when 'IN', 'EQUALS' {
                return field + ' IN :' + bindKey;
            }
            when 'NOT_IN', 'NOT_EQUALS' {
                return field + ' NOT IN :' + bindKey;
            }
            when 'INCLUDES' {
                return field + ' INCLUDES (:' + bindKey + ')';
            }
            when 'EXCLUDES' {
                return field + ' EXCLUDES (:' + bindKey + ')';
            }
            when 'LESS_THAN' {
                return field + ' < :' + bindKey;
            }
            when 'GREATER_THAN' {
                return field + ' > :' + bindKey;
            }
            when 'LESS_OR_EQUAL' {
                return field + ' <= :' + bindKey;
            }
            when 'GREATER_OR_EQUAL' {
                return field + ' >= :' + bindKey;
            }
            when else {
                Logger.warn('Unknown operator "' + op + '" on field ' + field
                        + ' — defaulting to IN')
                    .category(Logger.Category.QUERY_BUILD)
                    .inClass(CLS).inMethod('buildConditionClause')
                    .log();
                return field + ' IN :' + bindKey;
            }
        }
    }

    // ─── Bind Value Formatting ─────────────────────────────────────────────────

    /**
     * @description Formats bind map values into a human-readable string for logging.
     *              Bind values come from CMDT-configured STATIC conditions — safe to log
     *              (no PII). Example output: b0=[New, Working] | b1=[High, Medium]
     */
    private static String formatBindValues(Map<String, Object> binds) {
        if (binds == null || binds.isEmpty()) {
            return 'binds=none';
        }
        List<String> sortedKeys = new List<String>(binds.keySet());
        sortedKeys.sort();
        List<String> parts = new List<String>();
        for (String key : sortedKeys) {
            Object val = binds.get(key);
            parts.add(key + '=' + String.valueOf(val));
        }
        return String.join(parts, ' | ');
    }

    // ─── ORDER BY ──────────────────────────────────────────────────────────────

    // Whitelisted SOQL keywords for ORDER BY — defense-in-depth against CMDT misconfiguration
    private static final Set<String> VALID_DIRECTIONS = new Set<String>{ 'ASC', 'DESC' };
    private static final Set<String> VALID_NULL_HANDLING = new Set<String>{ 'NULLS FIRST', 'NULLS LAST' };

    /**
     * @description Builds the ORDER BY clause from Routing_Priority__mdt records.
     *              Each priority contributes: FieldName ASC|DESC NULLS FIRST|LAST
     *              Priorities are already sorted by Sort_Order__c in ConfigBundle.
     *              Sort direction and null handling are whitelist-validated before
     *              concatenation to prevent SOQL keyword injection.
     */
    private static String buildOrderBy(ConfigBundle bundle) {
        if (bundle.priorities == null || bundle.priorities.isEmpty()) {
            return '';
        }

        List<String> orderClauses = new List<String>();

        for (Routing_Priority__mdt pri : bundle.priorities) {
            String clause = pri.Sort_Field_API_Name__c;

            if (String.isNotBlank(pri.Sort_Direction__c)
                && VALID_DIRECTIONS.contains(pri.Sort_Direction__c.toUpperCase())
            ) {
                clause += ' ' + pri.Sort_Direction__c.toUpperCase();
            }

            if (String.isNotBlank(pri.Null_Handling__c)
                && VALID_NULL_HANDLING.contains(pri.Null_Handling__c.toUpperCase())
            ) {
                clause += ' ' + pri.Null_Handling__c.toUpperCase();
            }

            orderClauses.add(clause);
        }

        return String.join(orderClauses, ', ');
    }
}
