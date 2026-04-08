/**
 * @description Selector for SLA escalation candidates. Groups active work items
 *              by config, then dynamically queries the source records to check
 *              SLA deadline proximity and "acted on" status.
 *
 *              SOQL budget awareness:
 *              - 1 SOQL for all active work items (via WorkItemSelector.getAllActive)
 *              - 1 SOQL per distinct Object_API_Name (dynamic query for SLA + acted-on)
 *              - Total: 1 + N where N = unique object types with escalation-enabled configs
 *              - Typical case: N = 1–3 (Case, Lead, custom object)
 *
 *              Security:
 *              - Dynamic queries use Database.queryWithBinds() — zero injection surface.
 *              - AccessLevel.USER_MODE enforced on all queries.
 *
 * @group Selector
 */
public with sharing class EscalationSelector {

    private static final String CLS = 'EscalationSelector';

    /**
     * @description DTO holding a work item and its source record for escalation
     *              evaluation. Carries the SLA deadline and acted-on field value
     *              so EscalationService can decide without additional queries.
     */
    public class EscalationCandidate {
        public Agent_Work_Item__c workItem;
        public Datetime slaDeadline;
        public Object   actedOnFieldValue;
        public ConfigBundle bundle;
    }

    /**
     * @description Finds all active work items that may need escalation.
     *              For each escalation-enabled config:
     *              1. Collects active work items assigned under that config
     *              2. Dynamically queries source records for SLA deadline + acted-on field
     *              3. Returns enriched EscalationCandidate DTOs
     *
     *              Only queries configs where Escalation_Enabled__c = true AND
     *              SLA_Deadline_Field__c is populated.
     *
     * @param bundles List of active ConfigBundles (from ConfigLoader)
     * @return List of EscalationCandidate ready for threshold evaluation
     */
    public static List<EscalationCandidate> findCandidates(
        List<ConfigBundle> bundles
    ) {
        List<EscalationCandidate> candidates = new List<EscalationCandidate>();

        if (bundles == null || bundles.isEmpty()) {
            return candidates;
        }

        // ── Build map of escalation-enabled bundles by developer name ────
        Map<String, ConfigBundle> escalationBundles =
            new Map<String, ConfigBundle>();
        for (ConfigBundle b : bundles) {
            if (b.escalationEnabled
                && String.isNotBlank(b.slaDeadlineField)
                && b.slaMinutes != null
                && b.slaMinutes > 0
            ) {
                escalationBundles.put(b.developerName, b);
            }
        }

        if (escalationBundles.isEmpty()) {
            return candidates;
        }

        // ── Get all active work items (1 SOQL) ──────────────────────────
        List<Agent_Work_Item__c> allActive = WorkItemSelector.getAllActive();

        // ── Group work items by config developer name ───────────────────
        Map<String, List<Agent_Work_Item__c>> itemsByConfig =
            new Map<String, List<Agent_Work_Item__c>>();
        for (Agent_Work_Item__c item : allActive) {
            if (!escalationBundles.containsKey(item.Config_Developer_Name__c)) {
                continue;
            }
            if (!itemsByConfig.containsKey(item.Config_Developer_Name__c)) {
                itemsByConfig.put(
                    item.Config_Developer_Name__c,
                    new List<Agent_Work_Item__c>()
                );
            }
            itemsByConfig.get(item.Config_Developer_Name__c).add(item);
        }

        // ── For each config, query source records for SLA + acted-on ────
        for (String configName : itemsByConfig.keySet()) {
            ConfigBundle bundle = escalationBundles.get(configName);
            List<Agent_Work_Item__c> items = itemsByConfig.get(configName);

            List<EscalationCandidate> configCandidates =
                enrichWithSourceData(items, bundle);
            candidates.addAll(configCandidates);
        }

        return candidates;
    }

    // =========================================================================
    // PRIVATE
    // =========================================================================

    /**
     * @description Queries source records for SLA deadline and acted-on field,
     *              then builds EscalationCandidate DTOs. One SOQL per config's
     *              object type.
     *
     * @param items  Active work items for this config
     * @param bundle The ConfigBundle with SLA/acted-on field metadata
     * @return List of enriched EscalationCandidate DTOs
     */
    private static List<EscalationCandidate> enrichWithSourceData(
        List<Agent_Work_Item__c> items,
        ConfigBundle bundle
    ) {
        List<EscalationCandidate> result = new List<EscalationCandidate>();

        // Collect record IDs for bulk query
        Set<String> recordIds = new Set<String>();
        Map<String, Agent_Work_Item__c> itemsByRecordId =
            new Map<String, Agent_Work_Item__c>();
        for (Agent_Work_Item__c item : items) {
            recordIds.add(item.Record_Id__c);
            itemsByRecordId.put(item.Record_Id__c, item);
        }

        if (recordIds.isEmpty()) {
            return result;
        }

        // ── Build dynamic query ─────────────────────────────────────────
        // SELECT SLA field + optional acted-on field FROM object WHERE Id IN :recordIds
        String objectApiName = bundle.objectApiName;
        String slaField = bundle.slaDeadlineField;
        String actedOnField = bundle.actedOnField;

        // Validate fields exist on the object
        Schema.SObjectType sot = Schema.getGlobalDescribe().get(objectApiName);
        if (sot == null) {
            Logger.warn('Escalation: object not found | object=' + objectApiName)
                .category(Logger.Category.ENGINE)
                .inClass(CLS).inMethod('enrichWithSourceData')
                .log();
            return result;
        }
        Map<String, Schema.SObjectField> fieldMap = sot.getDescribe().fields.getMap();

        if (!fieldMap.containsKey(slaField.toLowerCase())) {
            Logger.warn('Escalation: SLA field not found | field='
                    + slaField + ' | object=' + objectApiName)
                .category(Logger.Category.ENGINE)
                .inClass(CLS).inMethod('enrichWithSourceData')
                .log();
            return result;
        }

        List<String> selectCols = new List<String>{ 'Id', slaField };
        Boolean hasActedOnField = String.isNotBlank(actedOnField)
            && fieldMap.containsKey(actedOnField.toLowerCase());
        if (hasActedOnField) {
            selectCols.add(actedOnField);
        }

        String soql = 'SELECT ' + String.join(selectCols, ', ')
            + ' FROM ' + objectApiName
            + ' WHERE Id IN :recordIds';

        Map<String, Object> bindMap = new Map<String, Object>();
        bindMap.put('recordIds', new List<String>(recordIds));

        List<SObject> sourceRecords;
        try {
            sourceRecords = Database.queryWithBinds(
                soql, bindMap, AccessLevel.USER_MODE
            );
        } catch (Exception ex) {
            Logger.error('Escalation query failed | ' + ex.getMessage())
                .category(Logger.Category.ENGINE)
                .inClass(CLS).inMethod('enrichWithSourceData')
                .log();
            return result;
        }

        // ── Map source data back to work items ──────────────────────────
        for (SObject rec : sourceRecords) {
            String recId = String.valueOf(rec.Id);
            Agent_Work_Item__c workItem = itemsByRecordId.get(recId);
            if (workItem == null) {
                continue;
            }

            EscalationCandidate ec = new EscalationCandidate();
            ec.workItem = workItem;
            ec.bundle = bundle;

            // Read SLA deadline
            Object slaVal = rec.get(slaField);
            ec.slaDeadline = (slaVal instanceof Datetime) ? (Datetime) slaVal : null;

            // Read acted-on field
            if (hasActedOnField) {
                ec.actedOnFieldValue = rec.get(actedOnField);
            }

            result.add(ec);
        }

        return result;
    }
}
