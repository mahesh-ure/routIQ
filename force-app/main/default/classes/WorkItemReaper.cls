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
     *              Work items are grouped by Config_Developer_Name__c so
     *              each group is evaluated against its own Routing_Config:
     *                • Object_API_Name__c         — target SObject
     *                • Closed_Status_Field_API_Name__c — the status field
     *                • Closed_Status_Values__c    — closed values
     *
     *              This lets the reaper handle any object/status field
     *              combo (Case.Status, Opportunity.StageName, Lead.Status,
     *              My_Object__c.State__c, …) without hardcoding.
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

        // ── Group work items by config developer name ──────────────────
        // Each config knows its own object + closed-status field + values.
        Map<String, List<Agent_Work_Item__c>> byConfig =
            new Map<String, List<Agent_Work_Item__c>>();

        for (Agent_Work_Item__c item : items) {
            String cfgName = item.Config_Developer_Name__c;
            if (String.isBlank(cfgName)) {
                continue;
            }
            if (!byConfig.containsKey(cfgName)) {
                byConfig.put(cfgName, new List<Agent_Work_Item__c>());
            }
            byConfig.get(cfgName).add(item);
        }

        // ── Process each config group ───────────────────────────────────
        Set<String> recordIdsToComplete = new Set<String>();

        for (String cfgName : byConfig.keySet()) {
            Routing_Config__mdt cfg = configs.get(cfgName);
            if (cfg == null) {
                // Config has been removed — every item under it is orphaned
                for (Agent_Work_Item__c item : byConfig.get(cfgName)) {
                    if (String.isNotBlank(item.Record_Id__c)) {
                        recordIdsToComplete.add(item.Record_Id__c);
                    }
                }
                continue;
            }
            reapConfigGroup(cfg, byConfig.get(cfgName), recordIdsToComplete);
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
     * @description Handles one config's worth of work items: queries their
     *              source records using the config's
     *              Closed_Status_Field_API_Name__c and flags closed or
     *              deleted records for reaping.
     *
     *              Cost: 1 SOQL per config group.
     *
     *              Graceful degradation:
     *               • Object no longer exists → everything orphaned → reap all.
     *               • Closed field missing / not configured → closure
     *                 detection is disabled for this group, but deletion
     *                 detection still runs.
     *               • Closed values blank → same as above.
     */
    private static void reapConfigGroup(
        Routing_Config__mdt cfg,
        List<Agent_Work_Item__c> configItems,
        Set<String> recordIdsToComplete
    ) {
        String objectApiName = cfg.Object_API_Name__c;
        String closedField   = cfg.Closed_Status_Field_API_Name__c;
        String ownerField    = String.isNotBlank(cfg.Owner_Field_API_Name__c)
            ? cfg.Owner_Field_API_Name__c : 'OwnerId';

        // Parse closed values for this config
        Set<String> closedValues = new Set<String>();
        if (String.isNotBlank(cfg.Closed_Status_Values__c)) {
            for (String s : cfg.Closed_Status_Values__c.split(',')) {
                String trimmed = s.trim();
                if (String.isNotBlank(trimmed)) {
                    closedValues.add(trimmed);
                }
            }
        }

        // Collect record Ids (skip malformed) and map recordId → expected User Id
        // (the User we assigned to the agent). Used below to detect records whose
        // OwnerId has been manually reassigned away from the agent (e.g. sent back
        // to a queue or integration user) — those work items are zombies and their
        // capacity must be freed.
        Set<Id> recIdSet = new Set<Id>();
        Map<Id, Id> expectedOwnerByRecord = new Map<Id, Id>();
        for (Agent_Work_Item__c item : configItems) {
            try {
                Id rid = Id.valueOf(item.Record_Id__c);
                recIdSet.add(rid);
                if (item.Agent__r != null && item.Agent__r.User__c != null) {
                    expectedOwnerByRecord.put(rid, item.Agent__r.User__c);
                }
            } catch (Exception ex) {
                // malformed — skip
            }
        }

        if (recIdSet.isEmpty()) {
            return;
        }

        // Validate object exists
        Schema.SObjectType sot =
            Schema.getGlobalDescribe().get(objectApiName);
        if (sot == null) {
            // Object no longer exists — reap every work item for it
            for (Id recId : recIdSet) {
                recordIdsToComplete.add(String.valueOf(recId));
            }
            return;
        }

        // Can we evaluate closed status for this config?
        Map<String, Schema.SObjectField> fieldMap =
            sot.getDescribe().fields.getMap();
        Boolean canEvalClosed =
               String.isNotBlank(closedField)
            && !closedValues.isEmpty()
            && fieldMap.containsKey(closedField.toLowerCase());

        Boolean canEvalOwner =
               fieldMap.containsKey(ownerField.toLowerCase())
            && !expectedOwnerByRecord.isEmpty();

        // ── Query source records (1 SOQL) ───────────────────────────────
        List<String> selectFields = new List<String>{ 'Id' };
        if (canEvalClosed) {
            selectFields.add(closedField);
        }
        if (canEvalOwner) {
            selectFields.add(ownerField);
        }
        String selectList = String.join(selectFields, ', ');
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
                    + ' | config=' + cfg.DeveloperName
                    + ' | ' + ex.getMessage())
                .category(Logger.Category.ENGINE)
                .inClass(CLS).inMethod('reapConfigGroup')
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

            // Source record closed → reap
            if (canEvalClosed) {
                Object statusVal = rec.get(closedField);
                if (statusVal != null
                    && closedValues.contains(String.valueOf(statusVal))) {
                    recordIdsToComplete.add(String.valueOf(recId));
                    continue;
                }
            }

            // Ownership moved away from the agent (manual re-queue, escalation
            // return to integration user / queue, manual re-assign) → reap so
            // the agent's Current_Load__c is decremented on next sync.
            if (canEvalOwner) {
                Id expectedUserId = expectedOwnerByRecord.get(recId);
                Object currentOwner = rec.get(ownerField);
                if (expectedUserId != null
                    && currentOwner != null
                    && String.valueOf(currentOwner) != String.valueOf(expectedUserId)) {
                    recordIdsToComplete.add(String.valueOf(recId));
                }
            }
        }
    }
}
