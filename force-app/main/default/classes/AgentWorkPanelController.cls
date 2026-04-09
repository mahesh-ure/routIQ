/**
 * @description Layer 5 -- AuraEnabled controller for the Agent Work Panel LWC
 *              (ureAgentWorkPanel). Provides four endpoints:
 *
 *              1. getAgentContext()  -- load agent record for current user (status, load, capacity)
 *              2. getNextWork()     -- delegate to RoutingService, return assignment + SLA deadline
 *              3. deferWork()       -- reset configured defer field, publish DEFERRED event
 *              4. getQueueDepth()   -- lightweight COUNT() of pending candidates
 *
 *              Security:
 *              - Agent resolved server-side from UserInfo.getUserId() -- no client-supplied
 *                agent ID that could be spoofed.
 *              - USER_MODE DML/SOQL enforces CRUD/FLS throughout.
 *              - Bind variables only -- zero SOQL injection surface.
 *
 *              Governor cost per method:
 *              - getAgentContext:  1 SOQL
 *              - getNextWork:     delegates to RoutingEngine (see RoutingEngine budget)
 *              - deferWork:       1 SOQL (config) + 1 SOQL (record) + 1 DML + 1 DML (event)
 *              - getQueueDepth:   1 SOQL
 *
 * @group Entry
 */
public with sharing class AgentWorkPanelController {

    private static final String CLS = 'AgentWorkPanelController';

    // =========================================================================
    // INNER CLASS -- Agent context DTO returned to LWC
    // =========================================================================

    /**
     * @description Lightweight DTO carrying the agent's current state to the LWC.
     *              Avoids exposing the full Agent__c SObject to the client.
     */
    public class AgentContext {
        @AuraEnabled public Id agentId;
        @AuraEnabled public String status;
        @AuraEnabled public Decimal currentLoad;
        @AuraEnabled public Decimal maxCapacity;
        @AuraEnabled public Boolean isActive;
        @AuraEnabled public Datetime lastAssigned;
    }

    // =========================================================================
    // INNER CLASS -- Work assignment DTO returned by getNextWork
    // =========================================================================

    /**
     * @description Enriched routing result that adds SLA deadline data for the
     *              client-side countdown timer. Wraps RoutingResult fields plus
     *              the SLA DateTime value read from the assigned record.
     */
    public class WorkAssignment {
        @AuraEnabled public Boolean success;
        @AuraEnabled public Id recordId;
        @AuraEnabled public String recordName;
        @AuraEnabled public String objectApiName;
        @AuraEnabled public Id assignedTo;
        @AuraEnabled public Id routingLogId;
        @AuraEnabled public String errorMessage;
        @AuraEnabled public Datetime slaDeadline;
        @AuraEnabled public String configDevName;
    }

    // =========================================================================
    // 1. getAgentContext -- load current user's Agent__c record
    // =========================================================================

    /**
     * @description Returns the Agent__c record for the running user. Resolved
     *              server-side via UserInfo.getUserId() -- never trusts a
     *              client-supplied agent Id.
     *
     *              Governor: 1 SOQL (USER_MODE).
     *
     * @return AgentContext DTO with status, load, capacity, active flag
     * @throws AuraHandledException when no Agent__c record exists for the user
     */
    @AuraEnabled(cacheable=true)
    public static AgentContext getAgentContext() {
        Id userId = UserInfo.getUserId();

        List<Agent__c> agents = [
            SELECT Id,
                   Availability_Status__c,
                   Current_Load__c,
                   Max_Capacity__c,
                   Is_Active__c,
                   Last_Assigned__c
            FROM   Agent__c
            WHERE  User__c = :userId
            AND    Is_Active__c = true
            WITH SECURITY_ENFORCED
            LIMIT  1            
        ];

        if (agents.isEmpty()) {
            throw new AuraHandledException(
                'No active Agent record found for the current user. '
                + 'Contact your administrator to create an Agent record.'
            );
        }

        Agent__c agent = agents[0];
        AgentContext ctx = new AgentContext();
        ctx.agentId     = agent.Id;
        ctx.status      = agent.Availability_Status__c;
        ctx.currentLoad = agent.Current_Load__c != null ? agent.Current_Load__c : 0;
        ctx.maxCapacity = agent.Max_Capacity__c != null ? agent.Max_Capacity__c : 5;
        ctx.isActive    = agent.Is_Active__c;
        ctx.lastAssigned = agent.Last_Assigned__c;

        return ctx;
    }

    // =========================================================================
    // 2. getNextWork -- route and return enriched assignment with SLA deadline
    // =========================================================================

    /**
     * @description Calls RoutingService.getNextRecord() and enriches the result
     *              with the SLA deadline timestamp read from the assigned record.
     *
     *              The SLA field API name comes from Routing_Config__mdt.SLA_Deadline_Field__c.
     *              If null or the field has no value, slaDeadline returns null and the
     *              LWC hides the countdown.
     *
     * @param configDevName  Optional developer name of a specific Routing_Config__mdt.
     *                       Null = route across all active configs.
     * @return WorkAssignment DTO with SLA deadline for client-side countdown
     */
    @AuraEnabled
    public static WorkAssignment getNextWork(String configDevName) {
        // Self-heal: reap any zombie work items (closed/deleted source records)
        // for this agent BEFORE the capacity check runs in AssignmentResolver.
        // This keeps Current_Load__c honest even when no Record-Triggered Flow
        // is wired to the invocable closer. Safe no-op if nothing to reap.
        try {
            WorkItemReaper.reapForCurrentUser();
        } catch (Exception ex) {
            Logger.warn('Pre-pull reap failed | ' + ex.getMessage())
                .category(Logger.Category.ENGINE)
                .inClass(CLS).inMethod('getNextWork')
                .log();
        }

        // Delegate to RoutingService (agent resolved internally via UserInfo)
        RoutingResult result = RoutingService.getNextRecord(
            null,       // objectApiName -- engine resolves from config
            null,       // recordId -- pull model, no specific record
            configDevName,
            false       // dryRun
        );

        WorkAssignment wa = new WorkAssignment();
        wa.success       = result.success;
        wa.recordId      = result.recordId;
        wa.recordName    = result.recordName;
        wa.objectApiName = result.objectApiName;
        wa.assignedTo    = result.assignedTo;
        wa.routingLogId  = result.routingLogId;
        wa.errorMessage  = result.errorMessage;
        wa.configDevName = configDevName;

        // Enrich with SLA deadline if routing succeeded
        if (result.success && result.recordId != null) {
            wa.slaDeadline = loadSlaDeadline(result.recordId, result.objectApiName, configDevName);
        }

        return wa;
    }

    // =========================================================================
    // 3. deferWork -- reset configured field and publish DEFERRED event
    // =========================================================================

    /**
     * @description Defers the currently assigned work item. Resets the field
     *              specified by Routing_Config__mdt.Defer_Reset_Field__c to the
     *              value in Defer_Reset_Value__c, then publishes a DEFERRED
     *              Platform Event.
     *
     *              If no defer fields are configured, throws an error -- admins
     *              must configure defer behavior per routing config.
     *
     * @param recordId      The record to defer (must be a valid SObject Id)
     * @param configDevName Developer name of the Routing_Config__mdt that
     *                      assigned this record (required for defer field lookup)
     * @return String 'OK' on success
     * @throws AuraHandledException on validation failure or DML error
     */
    @AuraEnabled
    public static String deferWork(Id recordId, String configDevName) {
        // ── Validate inputs ────────────────────────────────────────────
        if (recordId == null) {
            throw new AuraHandledException('Record Id is required to defer work.');
        }
        if (String.isBlank(configDevName)) {
            throw new AuraHandledException(
                'Config developer name is required to determine defer behavior.'
            );
        }

        // ── Load config for defer field metadata ───────────────────────
        Map<String, Routing_Config__mdt> allConfigs = RoutingConfigSelector.getAllConfigs();
        Routing_Config__mdt config = allConfigs.get(configDevName);

        if (config == null) {
            throw new AuraHandledException(
                'Routing config "' + configDevName + '" not found.'
            );
        }
        if (String.isBlank(config.Defer_Reset_Field__c)) {
            throw new AuraHandledException(
                'Defer is not configured for routing config "' + configDevName + '". '
                + 'Set Defer_Reset_Field__c and Defer_Reset_Value__c on the config.'
            );
        }

        String deferField = config.Defer_Reset_Field__c;
        String deferValue = config.Defer_Reset_Value__c;
        String objectApiName = config.Object_API_Name__c;

        // ── Validate field accessibility via describe ──────────────────
        Schema.SObjectType sot = Schema.getGlobalDescribe().get(objectApiName);
        if (sot == null) {
            throw new AuraHandledException(
                'Object "' + objectApiName + '" does not exist in this org.'
            );
        }
        Schema.DescribeFieldResult dfr = sot.getDescribe()
            .fields.getMap().get(deferField)?.getDescribe();
        if (dfr == null) {
            throw new AuraHandledException(
                'Defer field "' + deferField + '" does not exist on ' + objectApiName + '.'
            );
        }
        if (!dfr.isUpdateable()) {
            throw new AuraHandledException(
                'Current user lacks update access on '
                + objectApiName + '.' + deferField + '.'
            );
        }

        // ── Build and update the record ────────────────────────────────
        SObject record = sot.newSObject(recordId);
        record.put(deferField, castDeferValue(deferValue, dfr.getType()));

        Database.SaveResult sr = Database.update(
            record, false, AccessLevel.USER_MODE
        );

        if (!sr.isSuccess()) {
            String errors = '';
            for (Database.Error err : sr.getErrors()) {
                errors += err.getMessage() + '; ';
            }
            throw new AuraHandledException('Defer failed: ' + errors);
        }

        // ── Remove work item and sync agent load ───────────────────────
        WorkItemService.deferWorkItem(String.valueOf(recordId));

        // ── Publish DEFERRED Platform Event ────────────────────────────
        publishDeferredEvent(recordId, objectApiName, configDevName);

        return 'OK';
    }

    // =========================================================================
    // 4. getQueueDepth -- lightweight COUNT() of pending candidates
    // =========================================================================

    /**
     * @description Returns the count of unassigned candidate records matching
     *              the given routing config. Uses a lightweight COUNT() SOQL
     *              with USER_MODE for FLS enforcement.
     *
     *              The query filters:
     *              - Object from config.Object_API_Name__c
     *              - Closed statuses excluded (config.Closed_Status_Values__c)
     *              - Only counts unowned records (owner field IS NULL or is a Queue)
     *
     *              Governor: 1 SOQL.
     *
     * @param configDevName Developer name of the Routing_Config__mdt
     * @return Integer count of pending records in the queue
     */
    @AuraEnabled(cacheable=true)
    public static Integer getQueueDepth(String configDevName) {
        if (String.isBlank(configDevName)) {
            throw new AuraHandledException(
                'Config developer name is required for queue depth.'
            );
        }

        Map<String, Routing_Config__mdt> allConfigs = RoutingConfigSelector.getAllConfigs();
        Routing_Config__mdt config = allConfigs.get(configDevName);

        if (config == null) {
            throw new AuraHandledException(
                'Routing config "' + configDevName + '" not found.'
            );
        }

        String objectApiName = config.Object_API_Name__c;

        // Validate object exists
        Schema.SObjectType sot = Schema.getGlobalDescribe().get(objectApiName);
        if (sot == null) {
            throw new AuraHandledException(
                'Object "' + objectApiName + '" not found in schema.'
            );
        }

        // Build bind-variable COUNT() query
        String soql = 'SELECT COUNT() FROM ' + objectApiName;
        List<String> whereClauses = new List<String>();
        Map<String, Object> bindMap = new Map<String, Object>();

        // Exclude closed statuses
        if (String.isNotBlank(config.Closed_Status_Values__c)) {
            List<String> closedStatuses = new List<String>();
            for (String s : config.Closed_Status_Values__c.split(',')) {
                String trimmed = s.trim();
                if (String.isNotBlank(trimmed)) {
                    closedStatuses.add(trimmed);
                }
            }
            if (!closedStatuses.isEmpty()) {
                whereClauses.add('Status NOT IN :closedStatuses');
                bindMap.put('closedStatuses', closedStatuses);
            }
        }

        // Filter by record type if configured
        if (String.isNotBlank(config.Record_Type_Dev_Name__c)) {
            List<String> rtNames = new List<String>();
            for (String s : config.Record_Type_Dev_Name__c.split(',')) {
                String trimmed = s.trim();
                if (String.isNotBlank(trimmed)) {
                    rtNames.add(trimmed);
                }
            }
            if (!rtNames.isEmpty()) {
                whereClauses.add('RecordType.DeveloperName IN :rtNames');
                bindMap.put('rtNames', rtNames);
            }
        }

        if (!whereClauses.isEmpty()) {
            soql += ' WHERE ' + String.join(whereClauses, ' AND ');
        }

        return Database.countQueryWithBinds(soql, bindMap, AccessLevel.USER_MODE);
    }

    // =========================================================================
    // PRIVATE HELPERS
    // =========================================================================

    /**
     * @description Loads the SLA deadline DateTime value from the assigned record.
     *              Returns null if no SLA field is configured or the field has no value.
     */
    private static Datetime loadSlaDeadline(
        Id recordId,
        String objectApiName,
        String configDevName
    ) {
        // Determine SLA field from config
        String slaField = null;
        if (String.isNotBlank(configDevName)) {
            Map<String, Routing_Config__mdt> allConfigs = RoutingConfigSelector.getAllConfigs();
            Routing_Config__mdt config = allConfigs.get(configDevName);
            if (config != null) {
                slaField = config.SLA_Deadline_Field__c;
            }
        }

        if (String.isBlank(slaField)) {
            return null;
        }

        // Validate field exists on object
        Schema.SObjectType sot = Schema.getGlobalDescribe().get(objectApiName);
        if (sot == null) {
            return null;
        }
        if (sot.getDescribe().fields.getMap().get(slaField) == null) {
            return null;
        }

        // Query the SLA value -- bind variable for record Id
        String soql = 'SELECT ' + slaField + ' FROM ' + objectApiName
                     + ' WHERE Id = :recordId LIMIT 1';
        Map<String, Object> bindMap = new Map<String, Object>();
        bindMap.put('recordId', recordId);

        List<SObject> records = Database.queryWithBinds(
            soql, bindMap, AccessLevel.USER_MODE
        );

        if (records.isEmpty()) {
            return null;
        }

        Object val = records[0].get(slaField);
        return (val instanceof Datetime) ? (Datetime) val : null;
    }

    // decrementAgentLoad() removed — replaced by WorkItemService.deferWorkItem()
    // which deletes the Agent_Work_Item__c and syncs Current_Load__c from COUNT
    // of active items (single source of truth, no drift).

    /**
     * @description Publishes a DEFERRED Platform Event for real-time subscribers.
     *              Non-fatal -- publish failures are logged but never thrown.
     */
    private static void publishDeferredEvent(
        Id recordId,
        String objectApiName,
        String configDevName
    ) {
        try {
            Routing_Event__e evt = new Routing_Event__e(
                Event_Type__c            = 'DEFERRED',
                Record_Id__c             = String.valueOf(recordId),
                Object_API_Name__c       = objectApiName,
                Config_Developer_Name__c = configDevName,
                Assigned_To__c           = String.valueOf(UserInfo.getUserId()),
                Routed_At__c             = Datetime.now()
            );
            Database.SaveResult evtResult = EventBus.publish(evt);
            if (!evtResult.isSuccess()) {
                Logger.warn('DEFERRED event publish failed for record='
                        + recordId)
                    .category(Logger.Category.ENGINE)
                    .inClass(CLS)
                    .inMethod('publishDeferredEvent')
                    .log();
            }
        } catch (Exception ex) {
            Logger.warn('DEFERRED event exception | ' + ex.getMessage())
                .category(Logger.Category.ENGINE)
                .inClass(CLS)
                .inMethod('publishDeferredEvent')
                .log();
        }
    }

    /**
     * @description Casts a String defer value to the appropriate Apex type based
     *              on the target field's DisplayType. Supports the field types
     *              commonly used as defer reset targets.
     */
    private static Object castDeferValue(String value, Schema.DisplayType fieldType) {
        if (value == null) {
            return null;
        }

        switch on fieldType {
            when BOOLEAN {
                return Boolean.valueOf(value);
            }
            when DOUBLE, CURRENCY, PERCENT {
                return Decimal.valueOf(value);
            }
            when INTEGER {
                return Integer.valueOf(value);
            }
            when DATE {
                return Date.valueOf(value);
            }
            when DATETIME {
                return Datetime.valueOf(value);
            }
            when else {
                // String, Id, Picklist, TextArea, etc. -- pass through as-is
                return value;
            }
        }
    }
}
