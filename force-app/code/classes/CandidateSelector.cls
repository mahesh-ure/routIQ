/**
 * @description Executes candidate queries built by DynamicQueryBuilder.
 *
 *              Single responsibility: run Database.queryWithBinds() with
 *              AccessLevel.USER_MODE so FLS and sharing are enforced in
 *              one place across all routing paths.
 *
 *              Cost: 1 SOQL per call.
 *
 * @group Selector
 */
public with sharing class CandidateSelector {

    @TestVisible
    private static List<SObject> mockResults;

    /**
     * @description Executes the candidate query with FLS and sharing enforcement.
     * @param spec QuerySpec containing SOQL and typed bind map
     * @return Matching candidate records (may be empty)
     */
    public static List<SObject> query(QuerySpec spec) {
        if (Test.isRunningTest() && mockResults != null) {
            return mockResults;
        }
        return Database.queryWithBinds(
            spec.soql,
            spec.bindMap,
            AccessLevel.USER_MODE
        );
    }
}
