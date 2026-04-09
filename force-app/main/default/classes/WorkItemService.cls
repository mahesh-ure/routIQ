/**
 * @description Service layer for Agent_Work_Item__c lifecycle management.
 *              Provides create / complete / defer operations and keeps
 *              Agent__c.Current_Load__c synchronized from the COUNT of
 *              active work items (single source of truth — no drift).
 *
 *              Entry points:
 *              • createWorkItem()      — called by AssignmentResolver on successful routing
 *              • completeWorkItem()    — @InvocableMethod for Flow-based record closure
 *              • completeWorkItems()   — bulk version for trigger-based closure
 *              • deferWorkItem()       — called by AgentWorkPanelController.deferWork
 *              • escalateWorkItem()    — called by EscalationService on SLA breach
 *
 *              Security:
 *              - Internal service — uses SYSTEM_MODE for DML on package-owned
 *                objects (Agent_Work_Item__c, Agent__c). CRUD/FLS enforcement
 *                happens at the entry-point layer (controllers, invocables).
 *              - Agent resolved server-side — no client-supplied agent IDs.
 *
 *              Governor cost per method:
 *              - createWorkItem:     1 DML (insert) + 1 SOQL (count) + 1 DML (agent update)
 *              - completeWorkItem:   1 SOQL (lookup) + 1 DML (delete) + 1 SOQL (count) + 1 DML (agent update)
 *              - deferWorkItem:      1 SOQL (lookup) + 1 DML (delete) + 1 SOQL (count) + 1 DML (agent update)
 *
 * @group Service
 */
public with sharing class WorkItemService {

    private static final String CLS = 'WorkItemService';
    private static final String STATUS_ACTIVE    = 'Active';
    private static final String STATUS_COMPLETED = 'Completed';
    private static final String STATUS_DEFERRED  = 'Deferred';
    private static final String STATUS_ESCALATED = 'Escalated';

    // =========================================================================
    // CREATE — called by AssignmentResolver after successful assignment
    // =========================================================================

    /**
     * @description Creates an Agent_Work_Item__c record and synchronizes the
     *              agent's Current_Load__c from the count of active items.
     *
     * @param agentId           Agent__c record Id
     * @param recordId          18-char ID of the assigned record
     * @param objectApiName     API name of the assigned SObject
     * @param configDevName     DeveloperName of the Routing_Config__mdt
     */
    public static void createWorkItem(
        Id agentId,
        Id recordId,
        String objectApiName,
        String configDevName
    ) {
        if (agentId == null || recordId == null) {
            return;
        }

        try {
            Agent_Work_Item__c item = new Agent_Work_Item__c(
                Agent__c                 = agentId,
                Record_Id__c             = String.valueOf(recordId),
                Object_API_Name__c       = objectApiName,
                Config_Developer_Name__c = configDevName,
                Assigned_At__c           = System.now(),
                Status__c                = STATUS_ACTIVE
            );

            Database.SaveResult sr = Database.insert(
                item, false, AccessLevel.SYSTEM_MODE
            );

            if (!sr.isSuccess()) {
                Logger.warn('Work item insert failed | recordId=' + recordId
                        + ' | agent=' + agentId)
                    .category(Logger.Category.ASSIGNMENT)
                    .inClass(CLS).inMethod('createWorkItem')
                    .log();
            }

            // Sync agent load from count of active items
            syncAgentLoad(agentId);

        } catch (Exception ex) {
            Logger.warn('Work item creation exception | ' + ex.getMessage())
                .category(Logger.Category.ASSIGNMENT)
                .inClass(CLS).inMethod('createWorkItem')
                .log();
        }
    }

    // =========================================================================
    // COMPLETE — @InvocableMethod for Flow-based record closure
    // =========================================================================

    /**
     * @description Input DTO for the completeWorkItem invocable method.
     *              Allows Flow admins to close work items when records
     *              reach closed status via Record-Triggered Flows.
     */
    public class CompleteWorkItemInput {
        @InvocableVariable(
            label='Record Id'
            description='18-character ID of the record being closed/completed.'
            required=true
        )
        public String recordId;
    }

    /**
     * @description Invocable method for Flow Builder. Finds the Active work
     *              item for the given record ID, marks it Completed (deletes),
     *              and syncs the agent's load counter.
     *
     *              Called from Record-Triggered Flows when a record's status
     *              enters a closed value.
     *
     * @param inputs List of CompleteWorkItemInput (bulkified by Flow runtime)
     */
    @InvocableMethod(
        label='Complete Work Item'
        description='Closes the active work item for a record and decrements agent load. Use in Record-Triggered Flows when a record reaches closed status.'
        category='routIQ'
    )
    public static void completeWorkItem(List<CompleteWorkItemInput> inputs) {
        if (inputs == null || inputs.isEmpty()) {
            return;
        }

        Set<String> recordIds = new Set<String>();
        for (CompleteWorkItemInput input : inputs) {
            if (String.isNotBlank(input.recordId)) {
                recordIds.add(input.recordId);
            }
        }

        if (recordIds.isEmpty()) {
            return;
        }

        completeWorkItems(recordIds);
    }

    /**
     * @description Bulk-completes work items for a set of record IDs.
     *              Deletes the work item records and syncs agent load for
     *              each affected agent.
     *
     * @param recordIds Set of 18-char source record IDs to complete
     */
    public static void completeWorkItems(Set<String> recordIds) {
        Map<String, Agent_Work_Item__c> itemsByRecordId =
            WorkItemSelector.getActiveByRecordIds(recordIds);

        if (itemsByRecordId.isEmpty()) {
            return;
        }

        // Collect affected agents for load sync
        Set<Id> affectedAgentIds = new Set<Id>();
        List<Agent_Work_Item__c> toDelete = new List<Agent_Work_Item__c>();

        for (Agent_Work_Item__c item : itemsByRecordId.values()) {
            affectedAgentIds.add(item.Agent__c);
            toDelete.add(item);
        }

        // Delete work items
        Database.delete(toDelete, false, AccessLevel.SYSTEM_MODE);

        // Sync load for each affected agent
        for (Id agentId : affectedAgentIds) {
            syncAgentLoad(agentId);
        }
    }

    // =========================================================================
    // DEFER — called by AgentWorkPanelController.deferWork
    // =========================================================================

    /**
     * @description Removes the work item for a deferred record and syncs
     *              the agent's load counter. Called after the defer field
     *              reset DML in AgentWorkPanelController.
     *
     * @param recordId 18-char ID of the deferred record
     */
    public static void deferWorkItem(String recordId) {
        if (String.isBlank(recordId)) {
            return;
        }

        Agent_Work_Item__c item =
            WorkItemSelector.getActiveByRecordId(recordId);

        if (item == null) {
            return;
        }

        Id agentId = item.Agent__c;

        Database.delete(
            new List<Agent_Work_Item__c>{ item },
            false,
            AccessLevel.SYSTEM_MODE
        );

        syncAgentLoad(agentId);
    }

    // =========================================================================
    // ESCALATE — called by EscalationService on SLA breach
    // =========================================================================

    /**
     * @description Marks a work item as Escalated and removes it from the
     *              agent's active load. Called by EscalationService before
     *              re-routing the record.
     *
     * @param workItem The Agent_Work_Item__c being escalated
     */
    public static void escalateWorkItem(Agent_Work_Item__c workItem) {
        if (workItem == null) {
            return;
        }

        Id agentId = workItem.Agent__c;

        Database.delete(
            new List<Agent_Work_Item__c>{ workItem },
            false,
            AccessLevel.SYSTEM_MODE
        );

        syncAgentLoad(agentId);
    }

    // =========================================================================
    // LOAD SYNC — single source of truth
    // =========================================================================

    /**
     * @description Synchronizes Agent__c.Current_Load__c from the COUNT of
     *              active Agent_Work_Item__c records. This is the single source
     *              of truth — eliminates counter drift from edge cases.
     *
     *              Governor: 1 SOQL (count) + 1 DML (agent update).
     *
     * @param agentId The Agent__c record Id to sync
     */
    @TestVisible
    private static void syncAgentLoad(Id agentId) {
        if (agentId == null) {
            return;
        }

        try {
            Integer activeCount = WorkItemSelector.countActiveByAgentId(agentId);

            Agent__c agent = new Agent__c(
                Id = agentId,
                Current_Load__c = activeCount,
                Last_Assigned__c = System.now()
            );

            Database.update(agent, false, AccessLevel.SYSTEM_MODE);

        } catch (Exception ex) {
            Logger.warn('Agent load sync failed | agentId=' + agentId
                    + ' | reason=' + ex.getMessage())
                .category(Logger.Category.ASSIGNMENT)
                .inClass(CLS).inMethod('syncAgentLoad')
                .log();
        }
    }
}
