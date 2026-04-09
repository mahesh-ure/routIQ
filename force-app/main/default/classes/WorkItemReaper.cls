/**
 * @description Self-healing cleanup for Agent_Work_Item__c. Detects and
 *              completes "zombie" work items whose source record has
 *              entered a closed status (per Routing_Config__mdt.
 *              Closed_Status_Values__c) or has been deleted outright.
 *
 *              Why this class exists:
 *              Agent__c.Current_Load__c is derived from COUNT of active
 *              work items — the single source of truth. If work items
 *              never get completed (e.g. no Record-Triggered Flow wired to
 *              the invocable closer), Current_Load__c inflates forever.
 *              This reaper is the safety net that keeps the count honest
 *              without relying on admin-wired Flows.
 *
 *              Entry points:
 *              • reapForAgent(agentId)    — on-pull cleanup for one agent
 *                                           (called by AgentWorkPanelController
 *                                           before NBA routes)
 *              • reapForCurrentUser()     — convenience for the panel
 *              • reapAll()                — org-wide sweep
 *                                           (called by WorkItemReaperJob)
 *
 *              Governor awareness:
 *              - 1 SOQL per distinct Object_API_Name__c represented in the
 *                batch of work items (source record status check).
 *              - 1 SOQL + 1 DML for WorkItemService.completeWorkItems
 *                (shared across all reaped items).
 *              - Per-agent call is typically 1–2 distinct objects,
 *                so 3–4 SOQL total — cheap enough for every NBA click.
 *
 *              Security:
 *              - Source record queries use AccessLevel.USER_MODE so CRUD/FLS
 *                on the customer's object is enforced at read time.
 *              - Work item completion delegates to WorkItemService which
 *                uses SYSTEM_MODE for package-owned junction DML.
 *
 * @group Service
 */
public with sharing class WorkItemReaper {

    private static final String CLS = 'WorkItemReaper';
    private static final String STATUS_FIELD = 'Status';

    // =========================================================================
    // PUBLIC API
    // =========================================================================

    /**
     * @description Reaps zombie work items for a single agent. Called
     *              before each NBA pull so the agent's Current_Load__c
     *              reflects reality before capacity checks run.
     *
     * @param agentId The Agent__c record Id
     * @return Number of work items reaped
     */
    public static Integer reapForAgent(Id agentId) {
        if (agentId == null) {
            return 0;
        }
        return reapItems(WorkItemSelector.getActiveByAgentId(agentId));
    }

    /**
     * @description Reaps zombie work items for the running user's Agent.
     *              Silently returns 0 if the user has no Agent record.
     *
     * @return Number of work items reaped
     */
    public static Integer reapForCurrentUser() {
        List<Agent__c> agents = [
            SELECT Id
            FROM   Agent__c
            WHERE  User__c = :UserInfo.getUserId()
            AND    Is_Active__c = true
            LIMIT  1
        ];
        if (agents.isEmpty()) {
            return 0;
        }
        return reapForAgent(agents[0].Id);
    }

    /**
     * @description Reaps zombie work items across all agents. Intended for
     *              the WorkItemReaperJob scheduled entry point.
     *
     * @return Number of work items reaped
     */
    public static Integer reapAll() {
        return reapItems(WorkItemSelector.getAllActive());
    }

    // =========================================================================
    // CORE REAP LOGIC
    // =========================================================================

    /**
     * @description Given a list of active work items, finds those whose
     *              source record is in a configured closed status or no
     *              longer exists, and completes them via WorkItemService.
     *
     *              Work items are grouped by Object_API_Name__c so we issue
     *              at most one SOQL per distinct object type.
     *
     * @param items List of active work items to evaluate
     * @return Number of items reaped
     */
    @TestVisible
    private static Integer reapItems(List<Agent_Work_Item__c> items) {
        if (items == null || items.isEmpty()) {
            return 0;
        }

        // ── Load config cache once (CMDT — 0 SOQL) ──────────────────────
        Map<String, Routing_Config__mdt> configs =
            RoutingConfigSelector.getAllConfigs();

        // ── Group work items by object type ─────────────────────────────
        Map<String, List<Agent_Work_Item__c>> byObject =
            new Map<String, List<Agent_Work_Item__c>>();

        for (Agent_Work_Item__c item : items) {
            if (String.isBlank(item.Object_API_Name__c)) {
                continue;
            }
            if (!byObject.containsKey(item.Object_API_Name__c)) {
                byObject.put(
                    item.Object_API_Name__c,
                    new List<Agent_Work_Item__c>()
                );
            }
            byObject.get(item.Object_API_Name__c).add(item);
        }

        // ── Process each object group ───────────────────────────────────
        Set<String> recordIdsToComplete = new Set<String>();

        for (String objectApiName : byObject.keySet()) {
            reapObjectGroup(
                objectApiName,
                byObject.get(objectApiName),
                configs,
                recordIdsToComplete
            );
        }

        if (recordIdsToComplete.isEmpty()) {
            return 0;
        }

        // ── Delegate to service (handles DML + load sync) ───────────────
        WorkItemService.completeWorkItems(recordIdsToComplete);

        Logger.info('WorkItemReaper completed zombies'
                + ' | count=' + recordIdsToComplete.size())
            .category(Logger.Category.ENGINE)
            .inClass(CLS).inMethod('reapItems')
            .log();

        return recordIdsToComplete.size();
    }

    /**
     * @description Handles one object's worth of work items: queries their
     *              source records and adds any that are closed or missing
     *              to the reap set.
     *
     *              Uses 1 SOQL per object. Gracefully skips objects that
     *              no longer exist, have no Status field, or for which no
     *              closed values are configured.
     */
    private static void reapObjectGroup(
        String objectApiName,
        List<Agent_Work_Item__c> objectItems,
        Map<String, Routing_Config__mdt> configs,
        Set<String> recordIdsToComplete
    ) {
        // ── Collect record IDs and union of closed values across configs ─
        Set<Id>     recIdSet       = new Set<Id>();
        Set<String> closedValuesSet = new Set<String>();

        for (Agent_Work_Item__c item : objectItems) {
            // Parse record Id (skip malformed)
            Id recId;
            try {
                recId = Id.valueOf(item.Record_Id__c);
            } catch (Exception ex) {
                continue;
            }
            recIdSet.add(recId);

            // Pull this config's closed values
            Routing_Config__mdt cfg =
                configs.get(item.Config_Developer_Name__c);
            if (cfg == null || String.isBlank(cfg.Closed_Status_Values__c)) {
                continue;
            }
            for (String s : cfg.Closed_Status_Values__c.split(',')) {
                String trimmed = s.trim();
                if (String.isNotBlank(trimmed)) {
                    closedValuesSet.add(trimmed);
                }
            }
        }

        if (recIdSet.isEmpty()) {
            return;
        }

        // ── Validate object and Status field exist ──────────────────────
        Schema.SObjectType sot =
            Schema.getGlobalDescribe().get(objectApiName);
        if (sot == null) {
            // Object no longer exists — reap every work item for it
            for (Id recId : recIdSet) {
                recordIdsToComplete.add(String.valueOf(recId));
            }
            return;
        }

        Map<String, Schema.SObjectField> fieldMap =
            sot.getDescribe().fields.getMap();
        Boolean hasStatusField = fieldMap.containsKey(STATUS_FIELD.toLowerCase());

        // ── Query source records (1 SOQL) ───────────────────────────────
        String selectList = hasStatusField ? 'Id, Status' : 'Id';
        String soql = 'SELECT ' + selectList
                    + ' FROM '  + objectApiName
                    + ' WHERE Id IN :recIdSet';
        Map<String, Object> binds = new Map<String, Object>{
            'recIdSet' => recIdSet
        };

        Map<Id, SObject> foundRecords;
        try {
            foundRecords = new Map<Id, SObject>(
                Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE)
            );
        } catch (Exception ex) {
            Logger.warn('WorkItemReaper query failed'
                    + ' | object=' + objectApiName
                    + ' | ' + ex.getMessage())
                .category(Logger.Category.ENGINE)
                .inClass(CLS).inMethod('reapObjectGroup')
                .log();
            return;
        }

        // ── Evaluate each record ────────────────────────────────────────
        for (Id recId : recIdSet) {
            SObject rec = foundRecords.get(recId);

            // Source record deleted → reap
            if (rec == null) {
                recordIdsToComplete.add(String.valueOf(recId));
                continue;
            }

            // No Status field on object → can't determine closed; leave it
            if (!hasStatusField) {
                continue;
            }

            // No closed values configured → can't determine closed; leave it
            if (closedValuesSet.isEmpty()) {
                continue;
            }

            // Source record in closed status → reap
            Object statusVal = rec.get(STATUS_FIELD);
            if (statusVal != null
                && closedValuesSet.contains(String.valueOf(statusVal))) {
                recordIdsToComplete.add(String.valueOf(recId));
            }
        }
    }
}
