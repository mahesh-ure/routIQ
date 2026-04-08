/**
 * @description Selector for Agent_Work_Item__c records. Centralizes all SOQL
 *              for work item queries. Used by WorkItemService for lifecycle
 *              operations and by EscalationSelector for SLA threshold checks.
 *
 *              Security:
 *              - Internal selector for package-owned objects. CRUD/FLS
 *                enforcement happens at the entry-point layer (controllers,
 *                invocables), not repeated in internal selectors.
 *              - Bind variables only — zero SOQL injection surface.
 *
 *              Governor awareness:
 *              - Each public method costs 1 SOQL unless noted otherwise.
 *              - COUNT queries used where full records are not needed.
 *
 * @group Selector
 */
public with sharing class WorkItemSelector {

    private static final String CLS = 'WorkItemSelector';
    private static final String STATUS_ACTIVE = 'Active';

    // ─── Test Isolation ──────────────────────────────────────────────────────
    @TestVisible
    private static List<Agent_Work_Item__c> mockItems;

    // =========================================================================
    // PUBLIC METHODS
    // =========================================================================

    /**
     * @description Returns all Active work items for a given Agent__c record.
     *              Used by WorkItemService to compute accurate current load.
     *
     * @param agentId The Agent__c record Id
     * @return List of active work items for the agent
     */
    public static List<Agent_Work_Item__c> getActiveByAgentId(Id agentId) {
        if (mockItems != null) {
            List<Agent_Work_Item__c> filtered = new List<Agent_Work_Item__c>();
            for (Agent_Work_Item__c item : mockItems) {
                if (item.Agent__c == agentId && item.Status__c == STATUS_ACTIVE) {
                    filtered.add(item);
                }
            }
            return filtered;
        }

        return [
            SELECT Id, Record_Id__c, Object_API_Name__c,
                   Config_Developer_Name__c, Assigned_At__c, Status__c,
                   Agent__c
            FROM   Agent_Work_Item__c
            WHERE  Agent__c = :agentId
            AND    Status__c = :STATUS_ACTIVE
        ];
    }

    /**
     * @description Returns COUNT of Active work items for a given Agent__c Id.
     *              Lightweight alternative to full record query when only the
     *              count is needed for load synchronization.
     *
     * @param agentId The Agent__c record Id
     * @return Integer count of active work items
     */
    public static Integer countActiveByAgentId(Id agentId) {
        if (mockItems != null) {
            Integer count = 0;
            for (Agent_Work_Item__c item : mockItems) {
                if (item.Agent__c == agentId && item.Status__c == STATUS_ACTIVE) {
                    count++;
                }
            }
            return count;
        }

        return [
            SELECT COUNT()
            FROM   Agent_Work_Item__c
            WHERE  Agent__c = :agentId
            AND    Status__c = :STATUS_ACTIVE
        ];
    }

    /**
     * @description Finds an Active work item by its source record ID.
     *              Used by WorkItemService.completeWorkItem() to locate the
     *              work item when a record reaches closed status.
     *
     * @param recordId The 18-char ID of the source record (Case, Lead, etc.)
     * @return The matching active work item, or null if not found
     */
    public static Agent_Work_Item__c getActiveByRecordId(String recordId) {
        if (mockItems != null) {
            for (Agent_Work_Item__c item : mockItems) {
                if (item.Record_Id__c == recordId && item.Status__c == STATUS_ACTIVE) {
                    return item;
                }
            }
            return null;
        }

        List<Agent_Work_Item__c> items = [
            SELECT Id, Record_Id__c, Object_API_Name__c,
                   Config_Developer_Name__c, Assigned_At__c, Status__c,
                   Agent__c
            FROM   Agent_Work_Item__c
            WHERE  Record_Id__c = :recordId
            AND    Status__c = :STATUS_ACTIVE
            LIMIT  1
        ];

        return items.isEmpty() ? null : items[0];
    }

    /**
     * @description Returns all Active work items across all agents, grouped by
     *              Config_Developer_Name__c. Used by the SLA Escalation Job to
     *              batch-process escalation candidates per routing config.
     *
     *              Governor: 1 SOQL. Results bounded by platform limits.
     *
     * @return List of all active work items with agent and config context
     */
    public static List<Agent_Work_Item__c> getAllActive() {
        if (mockItems != null) {
            List<Agent_Work_Item__c> filtered = new List<Agent_Work_Item__c>();
            for (Agent_Work_Item__c item : mockItems) {
                if (item.Status__c == STATUS_ACTIVE) {
                    filtered.add(item);
                }
            }
            return filtered;
        }

        return [
            SELECT Id, Record_Id__c, Object_API_Name__c,
                   Config_Developer_Name__c, Assigned_At__c, Status__c,
                   Agent__c, Agent__r.User__c
            FROM   Agent_Work_Item__c
            WHERE  Status__c = :STATUS_ACTIVE
            ORDER BY Config_Developer_Name__c, Assigned_At__c ASC
        ];
    }

    /**
     * @description Bulk query: returns Active work items for a set of record IDs.
     *              Used by WorkItemService.completeWorkItems() for bulk closure.
     *
     * @param recordIds Set of 18-char source record IDs
     * @return Map of recordId -> Agent_Work_Item__c for active items
     */
    public static Map<String, Agent_Work_Item__c> getActiveByRecordIds(
        Set<String> recordIds
    ) {
        if (mockItems != null) {
            Map<String, Agent_Work_Item__c> result =
                new Map<String, Agent_Work_Item__c>();
            for (Agent_Work_Item__c item : mockItems) {
                if (recordIds.contains(item.Record_Id__c)
                    && item.Status__c == STATUS_ACTIVE) {
                    result.put(item.Record_Id__c, item);
                }
            }
            return result;
        }

        List<Agent_Work_Item__c> items = [
            SELECT Id, Record_Id__c, Object_API_Name__c,
                   Config_Developer_Name__c, Assigned_At__c, Status__c,
                   Agent__c
            FROM   Agent_Work_Item__c
            WHERE  Record_Id__c IN :recordIds
            AND    Status__c = :STATUS_ACTIVE
        ];

        Map<String, Agent_Work_Item__c> result =
            new Map<String, Agent_Work_Item__c>();
        for (Agent_Work_Item__c item : items) {
            result.put(item.Record_Id__c, item);
        }
        return result;
    }
}
