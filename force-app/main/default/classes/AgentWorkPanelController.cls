/**
 * @description Layer 5 -- AuraEnabled controller for the Agent Work Panel LWC.
 *   Endpoints: getAgentContext (cacheable), refreshAgentContext (reap + reload),
 *   getNextWork (pull-model routing), deferWork (reset field + event), getQueueDepth (COUNT).
 *   Security: agent resolved server-side via UserInfo; USER_MODE SOQL/DML; bind vars only.
 *   Governor: 1-5 SOQL per call depending on endpoint; see individual methods.
 * @group Entry
 */
public with sharing class AgentWorkPanelController {

    private static final String CLS = 'AgentWorkPanelController';

    /** @description Lightweight DTO carrying the agent's current state to the LWC. */
    public class AgentContext {
        @AuraEnabled public Id agentId;
        @AuraEnabled public String status;
        @AuraEnabled public Decimal currentLoad;
        @AuraEnabled public Decimal maxCapacity;
        @AuraEnabled public Boolean isActive;
        @AuraEnabled public Datetime lastAssigned;
    }

    /** @description Enriched routing result with SLA deadline for client-side countdown timer. */
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

    /**
     * @description Returns AgentContext for the running user. Cacheable -- no DML.
     * @return AgentContext DTO   @throws AuraHandledException if no Agent__c exists
     */
    @AuraEnabled(cacheable=true)
    public static AgentContext getAgentContext() {
        return loadAgentContext();
    }

    /**
     * @description Non-cacheable 10s auto-refresh: reaps zombie work items then returns fresh context.
     * @return AgentContext DTO reflecting load AFTER zombie cleanup
     */
    @AuraEnabled
    public static AgentContext refreshAgentContext() {
        // Step 1: Self-heal — closed/deleted source records → complete work
        // items → Current_Load__c is recomputed from COUNT of active items.
        // Non-fatal: a reaper exception must not break the panel refresh.
        try {
            WorkItemReaper.reapForCurrentUser();
        } catch (Exception ex) {
            Logger.warn('Auto-refresh reap failed | ' + ex.getMessage())
                .category(Logger.Category.ENGINE)
                .inClass(CLS).inMethod('refreshAgentContext')
                .log();
        }

        // Step 2: Return the freshly-loaded context (load reflects post-reap)
        return loadAgentContext();
    }

    /**
     * @description Shared Agent__c loader for getAgentContext and refreshAgentContext.
     *              Single source of truth for field list and DTO mapping. Cost: 1 SOQL.
     */
    private static AgentContext loadAgentContext() {
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
            throw new AuraHandledException(System.Label.URE_PANEL_NO_AGENT_ERROR);
        }

        Agent__c agent = agents[0];
        AgentContext ctx = new AgentContext();
        ctx.agentId      = agent.Id;
        ctx.status       = agent.Availability_Status__c;
        ctx.currentLoad  = agent.Current_Load__c != null ? agent.Current_Load__c : 0;
        ctx.maxCapacity  = agent.Max_Capacity__c != null ? agent.Max_Capacity__c : 5;
        ctx.isActive     = agent.Is_Active__c;
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
     * @description Defers work by resetting the defer field from config, removing the
     *              work item, and publishing a DEFERRED Platform Event. Requires defer
     *              fields to be configured on the Routing_Config__mdt.
     */
    @AuraEnabled
    public static String deferWork(Id recordId, String configDevName) {
        // Validate inputs
        if (recordId == null) {
            throw new AuraHandledException(System.Label.URE_PANEL_RECORD_ID_REQUIRED);
        }
        if (String.isBlank(configDevName)) {
            throw new AuraHandledException(System.Label.URE_PANEL_CONFIG_REQUIRED_DEFER);
        }

        // Load config for defer field metadata
        Map<String, Routing_Config__mdt> allConfigs = RoutingConfigSelector.getAllConfigs();
        Routing_Config__mdt config = allConfigs.get(configDevName);

        if (config == null) {
            throw new AuraHandledException(
                String.format(System.Label.URE_PANEL_CONFIG_NOT_FOUND, new List<Object>{configDevName})
            );
        }
        if (String.isBlank(config.Defer_Reset_Field__c)) {
            throw new AuraHandledException(
                String.format(System.Label.URE_PANEL_DEFER_NOT_CONFIGURED, new List<Object>{configDevName})
            );
        }

        String deferField = config.Defer_Reset_Field__c;
        String deferValue = config.Defer_Reset_Value__c;
        String objectApiName = config.Object_API_Name__c;

        // Validate field accessibility via describe
        Schema.SObjectType sot = Schema.getGlobalDescribe().get(objectApiName);
        if (sot == null) {
            throw new AuraHandledException(
                String.format(System.Label.URE_PANEL_OBJECT_NOT_FOUND, new List<Object>{objectApiName})
            );
        }
        Schema.DescribeFieldResult dfr = sot.getDescribe()
            .fields.getMap().get(deferField)?.getDescribe();
        if (dfr == null) {
            throw new AuraHandledException(
                String.format(System.Label.URE_PANEL_FIELD_NOT_FOUND, new List<Object>{deferField, objectApiName})
            );
        }
        if (!dfr.isUpdateable()) {
            throw new AuraHandledException(
                String.format(System.Label.URE_PANEL_NO_UPDATE_ACCESS, new List<Object>{objectApiName, deferField})
            );
        }

        // Build and update the record
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
            throw new AuraHandledException(
                String.format(System.Label.URE_PANEL_DEFER_FAILED, new List<Object>{errors})
            );
        }

        // Remove work item and sync agent load
        WorkItemService.deferWorkItem(String.valueOf(recordId));

        // Publish DEFERRED Platform Event
        publishDeferredEvent(recordId, objectApiName, configDevName);

        return 'OK';
    }

    /**
     * @description Returns COUNT of pending candidates for a config. When configDevName is blank,
     *              sums across ALL active configs (out-of-the-box fallback). Per-config errors
     *              are caught in fallback path so one bad config won't crash the panel.
     */
    @AuraEnabled(cacheable=true)
    public static Integer getQueueDepth(String configDevName) {
        // Fallback: sum across all active configs
        if (String.isBlank(configDevName)) {
            Integer total = 0;
            for (Routing_Config__mdt cfg : RoutingConfigSelector.getAllConfigs().values()) {
                if (cfg.Active__c != true) {
                    continue;
                }
                try {
                    total += countCandidatesForConfig(cfg);
                } catch (Exception ex) {
                    // Skip — one bad config must not break the widget.
                    Logger.warn('getQueueDepth fallback skipped config '
                            + cfg.DeveloperName + ' | ' + ex.getMessage())
                        .category(Logger.Category.ENGINE)
                        .inClass(CLS).inMethod('getQueueDepth')
                        .log();
                }
            }
            return total;
        }

        // Named-config path: hard error on lookup failure
        Map<String, Routing_Config__mdt> allConfigs = RoutingConfigSelector.getAllConfigs();
        Routing_Config__mdt config = allConfigs.get(configDevName);

        if (config == null) {
            throw new AuraHandledException(
                String.format(System.Label.URE_PANEL_CONFIG_NOT_FOUND, new List<Object>{configDevName})
            );
        }

        return countCandidatesForConfig(config);
    }

    /**
     * @description Counts pending candidates for a single config. Filters by closed status
     *              and record type. Throws if object not in schema. 1 SOQL (USER_MODE COUNT).
     */
    private static Integer countCandidatesForConfig(Routing_Config__mdt config) {
        String objectApiName = config.Object_API_Name__c;

        Schema.SObjectType sot = Schema.getGlobalDescribe().get(objectApiName);
        if (sot == null) {
            throw new AuraHandledException(
                String.format(System.Label.URE_PANEL_OBJECT_SCHEMA_ERROR, new List<Object>{objectApiName})
            );
        }

        String soql = 'SELECT COUNT() FROM ' + objectApiName;
        List<String> whereClauses = new List<String>();
        Map<String, Object> bindMap = new Map<String, Object>();

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

    /** @description Loads SLA deadline from the assigned record. Returns null if not configured. */
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
