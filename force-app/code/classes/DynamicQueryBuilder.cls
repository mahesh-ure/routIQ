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
 *              SOQL structure:
 *                SELECT  {Id, ownerField, selectFields}
 *                FROM    {objectApiName}
 *                WHERE   {condition clauses AND-joined}
 *                        [AND RecordType.DeveloperName IN :rtFilter]
 *                        [AND Id = :recId]
 *                ORDER BY {priority sort specs}
 *                LIMIT   {candidateLimit}
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

        URE_Logger.debug('SOQL assembled | object=' + fromClause
                + ' | whereClauses=' + bundle.conditions.size()
                + ' | orderByClauses=' + (bundle.priorities != null ? bundle.priorities.size() : 0)
                + ' | limit=' + limitValue
                + ' | bindKeys=' + binds.size())
            .category(URE_Logger.Category.QUERY_BUILD)
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
     * @description Builds the WHERE clause by AND-joining condition clauses,
     *              optional record-type filter, and optional single-record scope.
     */
    private static String buildWhere(
        ConfigBundle bundle,
        Map<String, Object> binds,
        String recordId
    ) {
        List<String> clauses = new List<String>();

        for (Integer i = 0; i < bundle.conditions.size(); i++) {
            Routing_Condition__mdt cond = bundle.conditions[i];
            String bindKey = 'b' + i;
            clauses.add(buildConditionClause(cond, bindKey));
        }

        // Record type filter
        if (!bundle.recordTypeDevNames.isEmpty()) {
            binds.put('rtFilter', bundle.recordTypeDevNames);
            clauses.add('RecordType.DeveloperName IN :rtFilter');
        }

        // Single-record scope
        if (String.isNotBlank(recordId)) {
            binds.put('recId', recordId);
            clauses.add('Id = :recId');
        }

        return String.join(clauses, ' AND ');
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
                URE_Logger.warn('Unknown operator "' + op + '" on field ' + field
                        + ' — defaulting to IN')
                    .category(URE_Logger.Category.QUERY_BUILD)
                    .inClass(CLS).inMethod('buildConditionClause')
                    .log();
                return field + ' IN :' + bindKey;
            }
        }
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
