/**
 * @description Immutable value object that holds everything needed to execute a
 *              candidate query via Database.queryWithBinds().
 *
 *              Created by DynamicQueryBuilder — consumed by RoutingEngine.
 *              Keeps the SOQL string, typed bind map, and object context together
 *              so they cannot fall out of sync.
 *
 *              The bind map values are already typed (List<Decimal>, List<String>, etc.)
 *              by ConditionBinder, so Database.queryWithBinds() generates correct
 *              SOQL literals without any string interpolation.
 *
 * @group Worker
 */
public with sharing class QuerySpec {

    public String soql        { get; private set; }
    public Map<String, Object> bindMap  { get; private set; }
    public String objectApiName { get; private set; }

    /**
     * @description Constructs a complete query specification.
     * @param soql           Fully assembled SOQL string with :bindKey placeholders
     * @param bindMap        Typed bind variables keyed by placeholder name (b0, b1, …)
     * @param objectApiName  SObject API name for logging and diagnostics
     */
    public QuerySpec(
        String soql,
        Map<String, Object> bindMap,
        String objectApiName
    ) {
        this.soql = soql;
        this.bindMap = bindMap;
        this.objectApiName = objectApiName;
    }
}
