/**
 * @description Layer 5 -- AuraEnabled controller for the Agent Work Panel LWC
 *              (ureAgentWorkPanel). Provides the five server endpoints the
 *              panel needs to load, refresh, route, defer, and gauge queue
 *              depth — split intentionally between cacheable (read-only,
 *              @wire-eligible) and non-cacheable (DML / mutation) methods so
 *              the LWC can use Lightning Data Service caching where it is
 *              safe and imperative calls where it is required.
 *
 *              Endpoints:
 *
 *              1. getAgentContext()      -- (cacheable) Initial wire load.
 *                                           Returns the running user's
 *                                           Agent__c state (status, load,
 *                                           capacity, last assigned).
 *
 *              2. refreshAgentContext()  -- (non-cacheable) The 10-second
 *                                           auto-refresh tick the panel
 *                                           fires from the client. Runs
 *                                           WorkItemReaper.reapForCurrentUser()
 *                                           server-side so the Current Load
 *                                           gauge drops as soon as the agent
 *                                           closes / deletes an assigned
 *                                           record, then returns the fresh
 *                                           AgentContext. Non-cacheable
 *                                           because it does DML — that is
 *                                           why it cannot be merged into
 *                                           getAgentContext.
 *
 *              3. getNextWork()          -- (non-cacheable) Pull-model entry
 *                                           point for the Next Best Action
 *                                           button. Delegates to
 *                                           RoutingService and enriches the
 *                                           result with the SLA deadline so
 *                                           the LWC's client-side countdown
 *                                           timer has its anchor.
 *
 *              4. deferWork()            -- (non-cacheable) Resets the
 *                                           configured defer field on the
 *                                           assigned record, removes the
 *                                           Agent_Work_Item__c so
 *                                           Current_Load__c drops, and
 *                                           publishes a DEFERRED Routing
 *                                           Platform Event for downstream
 *                                           subscribers.
 *
 *              5. getQueueDepth()        -- (cacheable) Lightweight COUNT()
 *                                           that powers the panel's Queue
 *                                           metric via @wire. Two modes:
 *                                           a) configDevName provided →
 *                                              count for that one config.
 *                                           b) configDevName blank/null →
 *                                              SUM across every active
 *                                              config (out-of-the-box
 *                                              fallback so the widget works
 *                                              before the admin binds the
 *                                              panel to a specific config).
 *
 *              Security:
 *              - Agent resolved server-side from UserInfo.getUserId() -- no
 *                client-supplied agent ID that could be spoofed.
 *              - USER_MODE DML/SOQL enforces CRUD/FLS throughout.
 *              - Bind variables only -- zero SOQL injection surface.
 *
 *              Governor cost per method:
 *              - getAgentContext:     1 SOQL
 *              - refreshAgentContext: 1 SOQL (agent) + reaper budget
 *                                     (typically 1 SOQL per distinct config
 *                                     in active work items, + at most 1 DML
 *                                     when zombies exist)
 *              - getNextWork:         delegates to RoutingEngine (see
 *                                     RoutingEngine budget) + reaper pre-pull
 *              - deferWork:           1 SOQL (config) + 1 SOQL (record) +
 *                                     1 DML (record update) + 1 DML (work
 *                                     item delete) + 1 DML (Platform Event)
 *              - getQueueDepth:       1 COUNT() per active config
 *                                     (typically ≤ 5 — well within limits)
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
     *              cacheable=true → safe for @wire and Lightning Data Service
     *              caching. NEVER add DML here; use refreshAgentContext()
     *              for the auto-refresh tick which needs to reap zombies.
     *
     * @return AgentContext DTO with status, load, capacity, active flag
     * @throws AuraHandledException when no Agent__c record exists for the user
     */
    @AuraEnabled(cacheable=true)
    public static AgentContext getAgentContext() {
        return loadAgentContext();
    }

    /**
     * @description Non-cacheable companion to getAgentContext() used by the
     *              Agent Work Panel's 10-second auto-refresh tick. Performs
     *              two operations:
     *
     *              1. WorkItemReaper.reapForCurrentUser() — completes any
     *                 Agent_Work_Item__c rows whose source record has been
     *                 closed or deleted by the agent since the last tick.
     *                 This synchronises Agent__c.Current_Load__c with reality
     *                 BEFORE the LWC reads it, so the load gauge drops as
     *                 soon as the agent closes a Case/Opportunity/etc.
     *
     *              2. Returns the freshly-loaded AgentContext.
     *
     *              The reap is wrapped in a try/catch — a reap failure must
     *              never break the auto-refresh. The agent context still
     *              returns even if cleanup hiccups.
     *
     *              Governor (typical): 1 SOQL (reaper agent lookup) +
     *              1 SOQL per distinct config in active work items + 1 DML
     *              (work item completion, only if zombies exist) +
     *              1 SOQL (agent context). Cheap enough for every 10s.
     *
     * @return AgentContext DTO reflecting load AFTER zombie cleanup
     * @throws AuraHandledException when no Agent__c record exists for the user
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
     * @description Shared loader used by both getAgentContext() (cacheable
     *              wire) and refreshAgentContext() (auto-refresh tick).
     *              Centralised so the field list and DTO mapping live in
     *              exactly one place — the two endpoints can never drift.
     *
     *              Cost: 1 SOQL.
     *
     * @return AgentContext DTO for the running user's Agent__c
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
            throw new AuraHandledException(
                'No active Agent record found for the current user. '
                + 'Contact your administrator to create an Agent record.'
            );
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
     *              FALLBACK BEHAVIOUR (added with @wire conversion of the LWC):
     *              When configDevName is null/blank, returns the SUM of pending
     *              candidates across ALL active routing configs. This makes the
     *              Agent Work Panel widget functional out-of-the-box on a fresh
     *              install where the admin has not yet bound the panel to a
     *              specific config via App Builder.
     *
     *              Per-config errors (missing object, missing FLS) are caught
     *              and skipped in the all-configs path — the widget is
     *              informational and must never crash the panel just because
     *              one config is misconfigured. A named-config call still
     *              throws on lookup failure (admin asked for a specific config
     *              and deserves a hard error).
     *
     *              Governor: 1 SOQL per active config (typically ≤ 5).
     *
     * @param configDevName Developer name of the Routing_Config__mdt, or
     *                      null/blank to sum across all active configs
     * @return Integer count of pending records in the queue
     */
    @AuraEnabled(cacheable=true)
    public static Integer getQueueDepth(String configDevName) {
        // ── Fallback path: no config locked → sum across all active configs ──
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

        // ── Named-config path: hard error on lookup failure ──
        Map<String, Routing_Config__mdt> allConfigs = RoutingConfigSelector.getAllConfigs();
        Routing_Config__mdt config = allConfigs.get(configDevName);

        if (config == null) {
            throw new AuraHandledException(
                'Routing config "' + configDevName + '" not found.'
            );
        }

        return countCandidatesForConfig(config);
    }

    /**
     * @description Counts pending candidate records for a single Routing_Config__mdt.
     *              Extracted from getQueueDepth so the same logic powers both the
     *              named-config path and the all-active-configs fallback.
     *
     *              Filters applied:
     *              - Object from config.Object_API_Name__c
     *              - Closed statuses excluded (config.Closed_Status_Values__c)
     *              - Record type filter (config.Record_Type_Dev_Name__c)
     *
     *              Throws if the object referenced by the config does not exist
     *              in the org. Caller is responsible for catching in the
     *              fallback path.
     *
     *              Governor: 1 SOQL (USER_MODE COUNT()).
     */
    private static Integer countCandidatesForConfig(Routing_Config__mdt config) {
        String objectApiName = config.Object_API_Name__c;

        Schema.SObjectType sot = Schema.getGlobalDescribe().get(objectApiName);
        if (sot == null) {
            throw new AuraHandledException(
                'Object "' + objectApiName + '" not found in schema.'
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
