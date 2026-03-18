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
 *              Cost: Zero SOQL, zero DML. Pure in-memory evaluation.
 *
 * @group Worker
 */
public with sharing class RuleEvaluator {

    private static final String CLS = 'RuleEvaluator';

    // ─── Inner Value Object ───────────────────────────────────────────────────

    public class EvaluationResult {
        public List<ConfigBundle> applicableBundles   { get; private set; }
        public List<String>       validationWarnings  { get; private set; }
        public Set<String>        requiredUserFields  { get; private set; }

        @TestVisible
        private EvaluationResult() {
            this.applicableBundles  = new List<ConfigBundle>();
            this.validationWarnings = new List<String>();
            this.requiredUserFields = new Set<String>();
        }
    }

    // ─── Public API ───────────────────────────────────────────────────────────

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
                URE_Logger.warn(warning)
                    .category(URE_Logger.Category.VALIDATION)
                    .inClass(CLS).inMethod('evaluate')
                    .forConfig(bundle.developerName)
                    .forObject(bundle.objectApiName)
                    .log();
                continue;
            }

            // ─── Bundle is applicable and valid ───────────────────────────
            result.applicableBundles.add(bundle);
            collectUserFields(bundle.conditions, result.requiredUserFields);
        }

        URE_Logger.debug('Rule evaluation complete | evaluated=' + bundles.size()
                + ' | applicable=' + result.applicableBundles.size()
                + ' | skippedNotApplicable=' + skippedNotApplicable
                + ' | validationWarnings=' + result.validationWarnings.size()
                + ' | userFields=' + result.requiredUserFields.size())
            .category(URE_Logger.Category.CONDITION_BIND)
            .inClass(CLS).inMethod('evaluate')
            .log();

        return result;
    }

    // ─── Applicability ────────────────────────────────────────────────────────

    @TestVisible
    private static Boolean isApplicable(
        ConfigBundle bundle,
        RoutingRequest request
    ) {
        if (String.isNotBlank(request.objectApiName)) {
            if (!request.objectApiName.equalsIgnoreCase(bundle.objectApiName)) {
                return false;
            }
        }

        if (String.isNotBlank(request.configDeveloperName)) {
            if (request.configDeveloperName != bundle.developerName) {
                return false;
            }
        }

        return true;
    }

    // ─── Validation ───────────────────────────────────────────────────────────

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

        if (bundle.conditions != null) {
            for (Integer i = 0; i < bundle.conditions.size(); i++) {
                Routing_Condition__mdt cond = bundle.conditions[i];

                if (String.isBlank(cond.Field_API_Name__c)) {
                    errors.add('Condition #' + (i + 1) + ': Field_API_Name__c is required.');
                }
                if (String.isBlank(cond.Operator__c)) {
                    errors.add('Condition #' + (i + 1) + ': Operator__c is required.');
                }
                if (cond.Value_Source__c == 'USER_ATTRIBUTE'
                    && String.isBlank(cond.User_Attribute_Field__c)
                ) {
                    errors.add('Condition #' + (i + 1)
                        + ': User_Attribute_Field__c is required for USER_ATTRIBUTE source.');
                }
                if (cond.Value_Source__c == 'STATIC'
                    && String.isBlank(cond.Values__c)
                ) {
                    errors.add('Condition #' + (i + 1) + ': Values__c is required for STATIC source.');
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

        return errors;
    }

    // ─── User Field Collection ────────────────────────────────────────────────

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
