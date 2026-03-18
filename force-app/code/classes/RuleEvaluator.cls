/**
 * @description Evaluates which ConfigBundles are applicable for a given RoutingRequest
 *              and validates bundle integrity before the engine spends SOQL on queries.
 *
 *              This is NOT a post-query in-memory filter — all routing conditions
 *              (STATIC, USER_ATTRIBUTE, all 10 operators) are translated into SOQL
 *              WHERE clauses by DynamicQueryBuilder and evaluated by the database.
 *
 *              RuleEvaluator's responsibility is CONFIG APPLICABILITY:
 *              1. Match request parameters to config definitions (object, config name).
 *              2. Validate each bundle is well-formed before processing.
 *              3. Collect all USER_ATTRIBUTE fields across applicable bundles for a
 *                 single optimized UserAttributeSelector query.
 *
 *              This keeps RoutingEngine as a pure orchestrator — zero filtering logic,
 *              zero validation logic, just method-to-method wiring.
 *
 *              Cost: Zero SOQL, zero DML. Pure in-memory evaluation.
 *
 * @group Worker
 */
public with sharing class RuleEvaluator {

    // ─── Inner Value Object ───────────────────────────────────────────────────

    /**
     * @description Result of evaluating all configs against a request.
     *              Bundles applicable configs, validation failures, and pre-collected
     *              user attribute fields in a single pass — no redundant iteration.
     */
    public class EvaluationResult {
        /** Configs that match the request and passed validation. */
        public List<ConfigBundle> applicableBundles   { get; private set; }

        /** Configs that failed validation — logged but not processed. */
        public List<String>       validationWarnings  { get; private set; }

        /**
         * Aggregated User field API names from USER_ATTRIBUTE conditions across
         * ALL applicable bundles. Fed to a single UserAttributeSelector.getAttributes()
         * call — 0 or 1 SOQL for the entire transaction regardless of bundle count.
         */
        public Set<String>        requiredUserFields  { get; private set; }

        @TestVisible
        private EvaluationResult() {
            this.applicableBundles  = new List<ConfigBundle>();
            this.validationWarnings = new List<String>();
            this.requiredUserFields = new Set<String>();
        }
    }

    // ─── Public API ───────────────────────────────────────────────────────────

    /**
     * @description Evaluates all active ConfigBundles against a RoutingRequest in a
     *              single pass. For each bundle:
     *              1. Checks applicability (object name, config name match).
     *              2. Validates structural integrity (required fields present).
     *              3. Collects USER_ATTRIBUTE field names for optimized User query.
     *
     *              Bundles that fail validation are excluded and logged as warnings
     *              — they do not halt the routing transaction.
     *
     * @param bundles All active ConfigBundles from ConfigLoader.loadActive()
     * @param request The routing request with optional filter criteria
     * @return EvaluationResult with applicable bundles, warnings, and user fields
     */
    public static EvaluationResult evaluate(
        List<ConfigBundle> bundles,
        RoutingRequest request
    ) {
        EvaluationResult result = new EvaluationResult();

        if (bundles == null || bundles.isEmpty()) {
            return result;
        }

        for (ConfigBundle bundle : bundles) {
            // ─── Applicability check ──────────────────────────────────────
            if (!isApplicable(bundle, request)) {
                continue;
            }

            // ─── Validation check ─────────────────────────────────────────
            List<String> errors = validateBundle(bundle);
            if (!errors.isEmpty()) {
                String warning = 'Config "' + bundle.developerName
                    + '" skipped: ' + String.join(errors, '; ');
                result.validationWarnings.add(warning);
                System.debug(LoggingLevel.WARN,
                    'RuleEvaluator: ' + warning);
                continue;
            }

            // ─── Bundle is applicable and valid ───────────────────────────
            result.applicableBundles.add(bundle);

            // Collect USER_ATTRIBUTE fields from this bundle's conditions
            collectUserFields(bundle.conditions, result.requiredUserFields);
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
     *              This catches bad CMDT configuration early — an admin might deploy a
     *              config with a blank Object_API_Name__c. Without validation, the engine
     *              would build malformed SOQL and waste a query.
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

        // Validate condition integrity
        if (bundle.conditions != null) {
            for (Integer i = 0; i < bundle.conditions.size(); i++) {
                Routing_Condition__mdt cond = bundle.conditions[i];

                if (String.isBlank(cond.Field_API_Name__c)) {
                    errors.add('Condition #' + (i + 1)
                        + ': Field_API_Name__c is required.');
                }

                if (String.isBlank(cond.Operator__c)) {
                    errors.add('Condition #' + (i + 1)
                        + ': Operator__c is required.');
                }

                // USER_ATTRIBUTE conditions must specify the User field
                if (cond.Value_Source__c == 'USER_ATTRIBUTE'
                    && String.isBlank(cond.User_Attribute_Field__c)
                ) {
                    errors.add('Condition #' + (i + 1)
                        + ': User_Attribute_Field__c is required for USER_ATTRIBUTE source.');
                }

                // STATIC conditions must have Values__c
                if (cond.Value_Source__c == 'STATIC'
                    && String.isBlank(cond.Values__c)
                ) {
                    errors.add('Condition #' + (i + 1)
                        + ': Values__c is required for STATIC source.');
                }
            }
        }

        // Validate priority integrity
        if (bundle.priorities != null) {
            for (Integer i = 0; i < bundle.priorities.size(); i++) {
                Routing_Priority__mdt pri = bundle.priorities[i];

                if (String.isBlank(pri.Sort_Field_API_Name__c)) {
                    errors.add('Priority #' + (i + 1)
                        + ': Sort_Field_API_Name__c is required.');
                }
            }
        }

        return errors;
    }

    // ─── User Field Collection ────────────────────────────────────────────────

    /**
     * @description Extracts User_Attribute_Field__c values from USER_ATTRIBUTE
     *              conditions and adds them to the accumulator set.
     *
     *              Called per-bundle during evaluate(). The accumulated set is used
     *              for a single UserAttributeSelector.getAttributes() call — avoiding
     *              N SOQL queries for N bundles.
     */
    private static void collectUserFields(
        List<Routing_Condition__mdt> conditions,
        Set<String> accumulator
    ) {
        if (conditions == null) {
            return;
        }

        for (Routing_Condition__mdt cond : conditions) {
            if (cond.Value_Source__c == 'USER_ATTRIBUTE'
                && String.isNotBlank(cond.User_Attribute_Field__c)
            ) {
                accumulator.add(cond.User_Attribute_Field__c);
            }
        }
    }
}
