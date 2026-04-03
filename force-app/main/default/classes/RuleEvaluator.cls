/**
 * @description Evaluates which ConfigBundles are applicable for a given RoutingRequest
 *              and validates bundle integrity before the engine spends SOQL on queries.
 *
 *              This is NOT a post-query in-memory filter — all routing conditions
 *              (STATIC only in v2, all 10 operators) are translated into SOQL
 *              WHERE clauses by DynamicQueryBuilder and evaluated by the database.
 *
 *              RuleEvaluator's responsibility is CONFIG APPLICABILITY:
 *              1. Match request parameters to config definitions (object, config name).
 *              2. Validate each bundle is well-formed before processing.
 *
 *              v2 change: USER_ATTRIBUTE field collection removed entirely.
 *              requiredUserFields removed from EvaluationResult. Agent-specific
 *              filtering is now handled by AgentMatcher, not ConditionBinder.
 *
 *              This keeps RoutingEngine as a pure orchestrator — zero filtering logic,
 *              zero validation logic, just method-to-method wiring.
 *
 *              Cost: Zero SOQL, zero DML. Pure in-memory evaluation.
 *
 * @group Worker
 */
public with sharing class RuleEvaluator {

    private static final String CLS = 'RuleEvaluator';

    // Scalar operators that accept only a single value — mirrors ConditionBinder
    private static final Set<String> SCALAR_OPERATORS = new Set<String>{
        'LESS_THAN', 'GREATER_THAN', 'LESS_OR_EQUAL', 'GREATER_OR_EQUAL'
    };

    /**
     * @description Result of evaluating all configs against a request.
     *              Bundles applicable configs and validation failures in a single pass.
     *
     *              v2: requiredUserFields removed — no longer needed.
     */
    public class EvaluationResult {
        /** Configs that match the request and passed validation. */
        public List<ConfigBundle> applicableBundles   { get; private set; }

        /** Configs that failed validation — logged but not processed. */
        public List<String>       validationWarnings  { get; private set; }

        @TestVisible
        private EvaluationResult() {
            this.applicableBundles  = new List<ConfigBundle>();
            this.validationWarnings = new List<String>();
        }
    }

    // ─── Public API ───────────────────────────────────────────────────────────

    /**
     * @description Evaluates all active ConfigBundles against a RoutingRequest in a
     *              single pass. For each bundle:
     *              1. Checks applicability (object name, config name match).
     *              2. Validates structural integrity (required fields present).
     *
     *              Bundles that fail validation are excluded and logged as warnings
     *              — they do not halt the routing transaction.
     *
     * @param bundles All active ConfigBundles from ConfigLoader.loadActive()
     * @param request The routing request with optional filter criteria
     * @return EvaluationResult with applicable bundles and warnings
     */
    public static EvaluationResult evaluate(
        List<ConfigBundle> bundles,
        RoutingRequest request
    ) {
        EvaluationResult result = new EvaluationResult();

        if (bundles == null || bundles.isEmpty()) {
            return result;
        }

        Integer skippedNotApplicable = 0;

        for (ConfigBundle bundle : bundles) {
            // ─── Applicability check ──────────────────────────────────────
            if (!isApplicable(bundle, request)) {
                skippedNotApplicable++;
                continue;
            }

            // ─── Validation check ─────────────────────────────────────────
            List<String> errors = validateBundle(bundle);
            if (!errors.isEmpty()) {
                String warning = 'Config "' + bundle.developerName
                    + '" skipped: ' + String.join(errors, '; ');
                result.validationWarnings.add(warning);
                Logger.warn(warning)
                    .category(Logger.Category.VALIDATION)
                    .inClass(CLS).inMethod('evaluate')
                    .forConfig(bundle.developerName)
                    .forObject(bundle.objectApiName)
                    .log();
                continue;
            }

            // ─── Bundle is applicable and valid ───────────────────────────
            result.applicableBundles.add(bundle);
        }

        return result;
    }

    // ─── Applicability ────────────────────────────────────────────────────────

    /**
     * @description Checks if a config matches the request's filter criteria.
     *
     *              Rules (AND-joined when multiple criteria present):
     *              • objectApiName specified → config.objectApiName must match
     *                (case-insensitive — admins may use different casing)
     *              • configDeveloperName specified → config.developerName must match
     *                (case-sensitive — DeveloperName is an Apex identifier)
     *              • No criteria → all configs are applicable ("Get Next" mode)
     */
    @TestVisible
    private static Boolean isApplicable(
        ConfigBundle bundle,
        RoutingRequest request
    ) {
        // Filter by object API name (case-insensitive)
        if (String.isNotBlank(request.objectApiName)) {
            if (!request.objectApiName.equalsIgnoreCase(bundle.objectApiName)) {
                return false;
            }
        }

        // Filter by config developer name (case-sensitive — DeveloperName is exact)
        if (String.isNotBlank(request.configDeveloperName)) {
            if (request.configDeveloperName != bundle.developerName) {
                return false;
            }
        }

        return true;
    }

    // ─── Validation ───────────────────────────────────────────────────────────

    /**
     * @description Validates a ConfigBundle has the minimum required fields to build
     *              a SOQL query and perform assignment. Called BEFORE spending any SOQL.
     *
     *              v2: USER_ATTRIBUTE validation removed — only STATIC source supported.
     *
     * @param bundle The config to validate
     * @return Empty list if valid. List of error strings if invalid.
     */
    @TestVisible
    private static List<String> validateBundle(ConfigBundle bundle) {
        List<String> errors = new List<String>();

        if (String.isBlank(bundle.objectApiName)) {
            errors.add('Object_API_Name__c is required.');
        }

        if (String.isBlank(bundle.ownerFieldApiName)) {
            errors.add('Owner_Field_API_Name__c is required.');
        }

        if (bundle.candidateLimit == null || bundle.candidateLimit <= 0) {
            errors.add('Candidate_Limit__c must be a positive number.');
        }

        // Validate condition integrity (STATIC only in v2)
        if (bundle.conditions != null) {
            for (Integer i = 0; i < bundle.conditions.size(); i++) {
                Routing_Condition__mdt cond = bundle.conditions[i];

                if (String.isBlank(cond.Field_API_Name__c)) {
                    errors.add('Condition #' + (i + 1) + ': Field_API_Name__c is required.');
                }
                if (String.isBlank(cond.Operator__c)) {
                    errors.add('Condition #' + (i + 1) + ': Operator__c is required.');
                }
                if (String.isBlank(cond.Values__c)) {
                    errors.add('Condition #' + (i + 1) + ': Values__c is required for STATIC source.');
                }

                // GAP 5: Warn when a scalar operator is paired with multiple values.
                // Only the first value is used — remaining values are silently ignored.
                if (String.isNotBlank(cond.Operator__c)
                    && SCALAR_OPERATORS.contains(cond.Operator__c)
                    && String.isNotBlank(cond.Values__c)
                    && cond.Values__c.contains(',')
                ) {
                    Logger.warn('Condition #' + (i + 1)
                            + ': Operator ' + cond.Operator__c
                            + ' is a scalar operator but Values__c contains multiple'
                            + ' comma-delimited values — only the first value will be used'
                            + ' | field=' + cond.Field_API_Name__c)
                        .category(Logger.Category.VALIDATION)
                        .inClass(CLS).inMethod('validateBundle')
                        .forConfig(bundle.developerName)
                        .log();
                }
            }
        }

        if (bundle.priorities != null) {
            for (Integer i = 0; i < bundle.priorities.size(); i++) {
                Routing_Priority__mdt pri = bundle.priorities[i];
                if (String.isBlank(pri.Sort_Field_API_Name__c)) {
                    errors.add('Priority #' + (i + 1) + ': Sort_Field_API_Name__c is required.');
                }
            }
        }

        // GAP 7: Validate Record_Type_Dev_Name__c against target object's RecordTypeInfos.
        // Some objects (e.g. Task in certain orgs) have no RecordTypes enabled —
        // routing would silently return zero results if a RecordType filter is configured.
        if (!bundle.recordTypeDevNames.isEmpty()
            && String.isNotBlank(bundle.objectApiName)
        ) {
            Schema.SObjectType sot = Schema.getGlobalDescribe().get(bundle.objectApiName);
            if (sot != null) {
                Map<String, Schema.RecordTypeInfo> rtInfos =
                    sot.getDescribe().getRecordTypeInfosByDeveloperName();
                // Salesforce always includes the "Master" RT — real RTs means > 1 entry
                if (rtInfos.size() <= 1) {
                    Logger.warn('Record_Type_Dev_Name__c is set but '
                            + bundle.objectApiName + ' has no Record Types enabled'
                            + ' — routing query will return zero results'
                            + ' | config=' + bundle.developerName)
                        .category(Logger.Category.VALIDATION)
                        .inClass(CLS).inMethod('validateBundle')
                        .forConfig(bundle.developerName)
                        .forObject(bundle.objectApiName)
                        .log();
                    errors.add('Record_Type_Dev_Name__c is configured but '
                        + bundle.objectApiName + ' has no Record Types enabled.');
                }
            }
        }

        return errors;
    }
}
