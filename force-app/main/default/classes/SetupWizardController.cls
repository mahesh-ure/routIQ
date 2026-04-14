/**
 * @description Apex controller for the Setup Wizard LWC (Layer 7). Provides five
 *              server-side operations that the wizard's step components call:
 *
 *              1. describeSObjectFields — Schema describe for the selected SObject
 *              2. getExistingConfigs     — Load existing Routing_Config__mdt records
 *              3. getActiveAgents        — Agent lookup for Step 4 agent picker
 *              4. simulateRouting        — Dry-run routing via RoutingService (Step 5)
 *              5. deployConfig           — CMDT deploy via Metadata.Operations +
 *                                          Agent__c / Skill_Bundle__c DML (Step 5)
 *              6. getDeployStatus        — Poll deployment status after activation
 *
 *              Security:
 *              • All SOQL uses AccessLevel.USER_MODE for CRUD/FLS enforcement.
 *              • Schema describe respects field-level visibility for the running user.
 *              • Metadata deploy requires Customize Application permission.
 *              • All inputs validated before use — no string interpolation in SOQL.
 *
 *              Governor awareness:
 *              • describeSObjectFields: 0 SOQL (Schema describe is governor-free)
 *              • getExistingConfigs: 0 SOQL (CMDT cached)
 *              • getActiveAgents: 1 SOQL (transaction-cached via selector)
 *              • simulateRouting: same cost as a normal route() minus DML
 *              • deployConfig: 1 Metadata.Operations.enqueueDeployment() +
 *                              1-3 DML (Agent__c, Skill_Bundle__c, entries)
 *
 * @group Controller
 */
public with sharing class SetupWizardController {

    private static final String CLS = 'SetupWizardController';

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP 1 — SObject field describe
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @description Returns field metadata for the given SObject, filtered to types
     *              compatible with routing conditions (Text, Picklist, Number, Boolean,
     *              Date, DateTime). Used by Step 3 to populate the dynamic field picklist.
     *
     *              Security: Schema.describeSObjectType() respects field-level security —
     *              fields the running user cannot see are excluded by the platform.
     *
     * @param sObjectType API name of the SObject (e.g. Case, Opportunity)
     * @return List of FieldDescribeResult DTOs for compatible fields
     * @throws AuraHandledException if sObjectType is invalid or inaccessible
     */
    @AuraEnabled(cacheable=true)
    public static List<FieldDescribeResult> describeSObjectFields(String sObjectType) {
        if (String.isBlank(sObjectType)) {
            throw new AuraHandledException(System.Label.URE_WIZARD_SOBJECT_REQUIRED);
        }

        Schema.SObjectType sobjType = Schema.getGlobalDescribe().get(sObjectType);
        if (sobjType == null) {
            throw new AuraHandledException(
                String.format(System.Label.URE_WIZARD_SOBJECT_NOT_FOUND,
                    new List<Object>{String.escapeSingleQuotes(sObjectType)})
            );
        }

        // Validate object-level accessibility
        Schema.DescribeSObjectResult objDescribe = sobjType.getDescribe();
        if (!objDescribe.isAccessible()) {
            throw new AuraHandledException(
                String.format(System.Label.URE_WIZARD_NO_ACCESS, new List<Object>{objDescribe.getLabel()})
            );
        }

        // Supported field types for routing conditions
        Set<Schema.DisplayType> supportedTypes = new Set<Schema.DisplayType>{
            Schema.DisplayType.STRING,
            Schema.DisplayType.PICKLIST,
            Schema.DisplayType.MULTIPICKLIST,
            Schema.DisplayType.DOUBLE,
            Schema.DisplayType.INTEGER,
            Schema.DisplayType.CURRENCY,
            Schema.DisplayType.PERCENT,
            Schema.DisplayType.BOOLEAN,
            Schema.DisplayType.DATE,
            Schema.DisplayType.DATETIME,
            Schema.DisplayType.REFERENCE,
            Schema.DisplayType.TEXTAREA,
            Schema.DisplayType.EMAIL,
            Schema.DisplayType.PHONE,
            Schema.DisplayType.URL
        };

        List<FieldDescribeResult> results = new List<FieldDescribeResult>();
        Map<String, Schema.SObjectField> fieldMap = objDescribe.fields.getMap();

        for (String fieldName : fieldMap.keySet()) {
            Schema.DescribeFieldResult fieldDesc = fieldMap.get(fieldName).getDescribe();

            // Skip fields the user cannot see (FLS enforcement)
            if (!fieldDesc.isAccessible()) {
                continue;
            }

            // Skip system fields that are not useful for routing conditions
            if (isSystemField(fieldDesc)) {
                continue;
            }

            // Filter to supported types
            if (!supportedTypes.contains(fieldDesc.getType())) {
                continue;
            }

            FieldDescribeResult fdr = new FieldDescribeResult();
            fdr.apiName = fieldDesc.getName();
            fdr.label = fieldDesc.getLabel();
            fdr.fieldType = fieldDesc.getType().name();
            fdr.picklistValues = getPicklistValues(fieldDesc);
            results.add(fdr);
        }

        results.sort();
        return results;
    }

    /**
     * @description DTO for field describe results, serialized to LWC.
     *              Implements Comparable for alphabetical sorting by label.
     */
    public class FieldDescribeResult implements Comparable {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;
        @AuraEnabled public String fieldType;
        @AuraEnabled public List<PicklistOption> picklistValues;

        public Integer compareTo(Object other) {
            FieldDescribeResult otherField = (FieldDescribeResult) other;
            if (this.label == null) { return -1; }
            if (otherField.label == null) { return 1; }
            return this.label.compareTo(otherField.label);
        }
    }

    /**
     * @description DTO for picklist value options, used by Step 3 condition builder.
     */
    public class PicklistOption {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP 2 — Existing config retrieval
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @description Returns all existing Routing_Config__mdt records for display
     *              in the wizard. Allows the wizard to show existing configs and
     *              prevent duplicate creation.
     *
     * @return List of ConfigSummary DTOs
     */
    @AuraEnabled(cacheable=true)
    public static List<ConfigSummary> getExistingConfigs() {
        Map<String, Routing_Config__mdt> configs =
            RoutingConfigSelector.getAllConfigs();

        List<ConfigSummary> summaries = new List<ConfigSummary>();
        for (Routing_Config__mdt config : configs.values()) {
            ConfigSummary cs = new ConfigSummary();
            cs.developerName = config.DeveloperName;
            cs.label = config.Label;
            cs.objectApiName = config.Object_API_Name__c;
            cs.isActive = config.Active__c;
            summaries.add(cs);
        }
        return summaries;
    }

    /**
     * @description Summary DTO for existing routing configs.
     */
    public class ConfigSummary {
        @AuraEnabled public String developerName;
        @AuraEnabled public String label;
        @AuraEnabled public String objectApiName;
        @AuraEnabled public Boolean isActive;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP 4 — Agent retrieval
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @description Returns active agents for the agent picker in Step 4.
     *              Uses the existing AgentCapabilitySelector which is already
     *              transaction-cached.
     *
     * @return List of AgentInfo DTOs with user details
     */
    @AuraEnabled(cacheable=true)
    public static List<AgentInfo> getActiveAgents() {
        Map<Id, Agent__c> agentsByUser =
            AgentCapabilitySelector.getActiveAgentsByUserId();

        List<AgentInfo> agents = new List<AgentInfo>();
        if (agentsByUser.isEmpty()) {
            return agents;
        }

        // Collect User Ids to query with Profile & Manager info
        Set<Id> userIds = agentsByUser.keySet();
        String soql = 'SELECT Id, Name, Email, ProfileId, Profile.Name, ManagerId, Manager.Name '
            + 'FROM User WHERE Id IN :userIds';
        Map<String, Object> binds = new Map<String, Object>{
            'userIds' => new List<Id>(userIds)
        };

        List<SObject> users = Database.queryWithBinds(
            soql, binds, AccessLevel.USER_MODE
        );

        Map<Id, User> userMap = new Map<Id, User>();
        for (SObject u : users) {
            userMap.put(u.Id, (User) u);
        }

        for (Id userId : agentsByUser.keySet()) {
            Agent__c agent = agentsByUser.get(userId);
            User u = userMap.get(userId);

            AgentInfo ai = new AgentInfo();
            ai.agentId = agent.Id;
            ai.userId = userId;
            ai.userName = (u != null) ? u.Name : String.valueOf(userId);
            ai.userEmail = (u != null) ? u.Email : '';
            ai.profileId = (u != null) ? u.ProfileId : null;
            ai.profileName = (u != null && u.Profile != null) ? u.Profile.Name : '';
            ai.managerId = (u != null) ? u.ManagerId : null;
            ai.managerName = (u != null && u.Manager != null) ? u.Manager.Name : '';
            ai.maxCapacity = (agent.Max_Capacity__c != null)
                ? agent.Max_Capacity__c.intValue() : 0;
            ai.currentLoad = (agent.Current_Load__c != null)
                ? agent.Current_Load__c.intValue() : 0;
            agents.add(ai);
        }

        return agents;
    }

    /**
     * @description DTO for agent information used by Step 4.
     *              Includes Profile and Manager info for filtering.
     */
    public class AgentInfo {
        @AuraEnabled public Id agentId;
        @AuraEnabled public Id userId;
        @AuraEnabled public String userName;
        @AuraEnabled public String userEmail;
        @AuraEnabled public Id profileId;
        @AuraEnabled public String profileName;
        @AuraEnabled public Id managerId;
        @AuraEnabled public String managerName;
        @AuraEnabled public Integer maxCapacity;
        @AuraEnabled public Integer currentLoad;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP 4 — User search (fresh-install support)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @description Searches active Salesforce Users for the Step 4 agent picker.
     *              Unlike getActiveAgents() — which only returns users with existing
     *              Agent__c records — this method queries ALL active Users so the
     *              wizard works on a fresh install (zero Agent__c records).
     *
     *              If a User already has an Agent__c record, agentId and capacity
     *              are populated from it. Otherwise, agentId is null and defaults
     *              are shown.
     *
     *              Search is optional: passing blank returns the first 200 active users.
     *
     * @param searchTerm Optional name filter (LIKE match). Blank = no filter.
     * @return List of AgentInfo DTOs for matching active users
     */
    @AuraEnabled
    public static List<AgentInfo> searchAvailableUsers(String searchTerm) {
        // Query active users, optionally filtered by name
        String soql;
        Map<String, Object> binds = new Map<String, Object>();
        binds.put('isActive', true);

        if (String.isNotBlank(searchTerm) && searchTerm.trim().length() >= 2) {
            soql = 'SELECT Id, Name, Email, ProfileId, Profile.Name, '
                + 'ManagerId, Manager.Name '
                + 'FROM User '
                + 'WHERE IsActive = :isActive '
                + 'AND Name LIKE :searchPattern '
                + 'ORDER BY Name LIMIT 200';
            binds.put('searchPattern', '%' + searchTerm.trim() + '%');
        } else {
            soql = 'SELECT Id, Name, Email, ProfileId, Profile.Name, '
                + 'ManagerId, Manager.Name '
                + 'FROM User '
                + 'WHERE IsActive = :isActive '
                + 'ORDER BY Name LIMIT 200';
        }

        List<SObject> users = Database.queryWithBinds(
            soql, binds, AccessLevel.USER_MODE
        );

        if (users.isEmpty()) {
            return new List<AgentInfo>();
        }

        // Collect user IDs to check for existing Agent__c records
        Set<Id> userIds = new Set<Id>();
        for (SObject u : users) {
            userIds.add(u.Id);
        }

        // Query existing Agent__c records for these users
        String agentSoql = 'SELECT Id, User__c, Max_Capacity__c, Current_Load__c '
            + 'FROM Agent__c WHERE User__c IN :userIds AND Is_Active__c = :isActive';
        Map<String, Object> agentBinds = new Map<String, Object>{
            'userIds' => new List<Id>(userIds),
            'isActive' => true
        };

        List<SObject> agentRecords = Database.queryWithBinds(
            agentSoql, agentBinds, AccessLevel.USER_MODE
        );

        Map<Id, Agent__c> existingAgents = new Map<Id, Agent__c>();
        for (SObject rec : agentRecords) {
            Agent__c agent = (Agent__c) rec;
            existingAgents.put(agent.User__c, agent);
        }

        // Build results — merge User + optional Agent__c data
        List<AgentInfo> results = new List<AgentInfo>();
        for (SObject sobj : users) {
            User u = (User) sobj;
            Agent__c existingAgent = existingAgents.get(u.Id);

            AgentInfo ai = new AgentInfo();
            ai.agentId = (existingAgent != null) ? existingAgent.Id : null;
            ai.userId = u.Id;
            ai.userName = u.Name;
            ai.userEmail = u.Email;
            ai.profileId = u.ProfileId;
            ai.profileName = (u.Profile != null) ? u.Profile.Name : '';
            ai.managerId = u.ManagerId;
            ai.managerName = (u.Manager != null) ? u.Manager.Name : '';
            ai.maxCapacity = (existingAgent != null && existingAgent.Max_Capacity__c != null)
                ? existingAgent.Max_Capacity__c.intValue() : 0;
            ai.currentLoad = (existingAgent != null && existingAgent.Current_Load__c != null)
                ? existingAgent.Current_Load__c.intValue() : 0;
            results.add(ai);
        }

        return results;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP 5 — Simulate (dry run)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @description Runs a dry-run simulation via RoutingService. The engine executes
     *              full matching logic but skips all DML, EventBus.publish(), and
     *              Routing_Log__c writes. Returns the RoutingResult with reasonSummary
     *              and conditionTraces for display.
     *
     *              This method depends on Layer 2 implementing dryRun support in
     *              RoutingService. Until then, the simulate step will show an error.
     *
     * @param recordId        ID of a sample record to simulate routing for
     * @param configDevName   DeveloperName of the config to test
     * @return SimulateResult with routing outcome details
     * @throws AuraHandledException on invalid input
     */
    @AuraEnabled
    public static SimulateResult simulateRouting(
        String recordId,
        String configDevName
    ) {
        if (String.isBlank(recordId)) {
            throw new AuraHandledException(System.Label.URE_WIZARD_RECORD_REQUIRED);
        }

        if (String.isBlank(configDevName)) {
            throw new AuraHandledException(System.Label.URE_WIZARD_CONFIG_REQUIRED_SIM);
        }

        // Validate recordId format
        String trimmedId = recordId.trim();
        if (trimmedId.length() != 15 && trimmedId.length() != 18) {
            throw new AuraHandledException(System.Label.URE_WIZARD_INVALID_RECORD_ID);
        }

        RoutingRequest request = new RoutingRequest();
        request.recordId = trimmedId;
        request.configDevName = configDevName;
        request.dryRun = true;

        // Determine objectApiName from recordId
        try {
            Id parsedId = Id.valueOf(trimmedId);
            request.objectApiName = parsedId.getSObjectType().getDescribe().getName();
        } catch (Exception ex) {
            throw new AuraHandledException(System.Label.URE_WIZARD_CANNOT_DETERMINE_TYPE);
        }

        // Call RoutingService — dryRun prevents all side effects (Layer 2)
        RoutingResult result = RoutingService.getNextRecord(
            request.objectApiName,
            request.recordId,
            request.configDevName,
            true  // dryRun — simulate without DML
        );

        SimulateResult sr = new SimulateResult();
        sr.success = result.success;
        sr.reasonSummary = result.reasonSummary;
        sr.errorMessage = result.errorMessage;
        sr.conditionTraces = result.conditionTraces;
        sr.assignedTo = result.assignedTo;
        return sr;
    }

    /**
     * @description DTO for simulation results displayed in Step 5.
     */
    public class SimulateResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String reasonSummary;
        @AuraEnabled public String errorMessage;
        @AuraEnabled public List<RoutingConditionTrace> conditionTraces;
        @AuraEnabled public String assignedTo;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP 5 — Deploy (activate)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @description Deploys the wizard configuration as Routing_Config__mdt and
     *              Routing_Condition__mdt records via Metadata.Operations.
     *
     *              CMDT deploy is asynchronous — returns a deployment ID that the
     *              LWC polls via getDeployStatus().
     *
     *              Agent__c records are created in SetupWizardDeployCallback AFTER
     *              CMDT deployment succeeds, preserving atomicity. If CMDT fails,
     *              no Agent__c records are created.
     *
     * @param wizardStateJson JSON-serialized wizard state from the parent LWC
     * @return DeployResult with the deployment ID for polling
     * @throws AuraHandledException on invalid input or deploy failure
     */
    @AuraEnabled
    public static DeployResult deployConfig(String wizardStateJson) {
        if (String.isBlank(wizardStateJson)) {
            throw new AuraHandledException(System.Label.URE_WIZARD_STATE_REQUIRED);
        }

        WizardState state;
        try {
            state = (WizardState) JSON.deserialize(wizardStateJson, WizardState.class);
        } catch (Exception ex) {
            throw new AuraHandledException(
                String.format(System.Label.URE_WIZARD_STATE_INVALID, new List<Object>{ex.getMessage()})
            );
        }

        // Validate required fields
        validateWizardState(state);

        DeployResult deployResult = new DeployResult();

        // ── Part 1: Deploy CMDT via Metadata.Operations ──────────────────
        Metadata.DeployContainer container = new Metadata.DeployContainer();

        // Build Routing_Config__mdt
        Metadata.CustomMetadata configRecord = buildConfigMetadata(state);
        container.addMetadata(configRecord);

        // Build Routing_Condition__mdt records
        if (state.conditions != null) {
            Integer sortOrder = 1;
            for (WizardCondition condition : state.conditions) {
                Metadata.CustomMetadata condRecord = buildConditionMetadata(
                    state, condition, sortOrder
                );
                container.addMetadata(condRecord);
                sortOrder++;
            }
        }

        // ── Part 2: Prepare callback with agent data ─────────────────
        // Agent DML is deferred to the callback so records are only created
        // AFTER CMDT deployment succeeds — preserving atomicity.
        String agentDataJson = null;
        if (state.agents != null && !state.agents.isEmpty()) {
            agentDataJson = JSON.serialize(state.agents);
        }

        SetupWizardDeployCallback callback = new SetupWizardDeployCallback(
            state.configDevName,
            agentDataJson,
            state.maxCapacity
        );

        // Enqueue deployment — asynchronous
        try {
            Id deployId = Metadata.Operations.enqueueDeployment(container, callback);
            deployResult.deploymentId = state.configDevName;
            deployResult.success = true;
            deployResult.message = 'Configuration deployment started.';
        } catch (Exception ex) {
            throw new AuraHandledException(
                String.format(System.Label.URE_WIZARD_DEPLOY_START_FAILED, new List<Object>{ex.getMessage()})
            );
        }

        return deployResult;
    }

    /**
     * @description Checks the status of a Metadata deployment.
     *
     *              Since Tooling API (DeployRequest) may not be available in all
     *              scratch org configurations, we use a simpler approach:
     *              - Try to query the Routing_Config__mdt to verify deployment success
     *              - If found, assume deployment succeeded
     *              - If not found after delay, assume deployment is still pending
     *
     *              This avoids SOQL permission issues and works in all orgs.
     *
     * @param deploymentId The Id returned by deployConfig() (stored in configDevName as context)
     * @return DeployStatusResult with current deployment status
     */
    @AuraEnabled
    public static DeployStatusResult getDeployStatus(String deploymentId) {
        if (String.isBlank(deploymentId)) {
            throw new AuraHandledException(System.Label.URE_WIZARD_DEPLOY_ID_REQUIRED);
        }

        DeployStatusResult status = new DeployStatusResult();

        try {
            // ── Tier 1: Check Platform Cache for callback result ────────
            // The DeployCallback stores success/failure here immediately
            // after the async deployment completes — gives us real error messages.
            SetupWizardDeployCallback.DeployOutcome cachedResult =
                SetupWizardDeployCallback.getStoredResult(deploymentId);

            if (cachedResult != null) {
                status.done = true;
                status.success = cachedResult.success;
                status.status = cachedResult.status;
                status.errorMessage = cachedResult.errorMessage;

                // Clean up cache entry after retrieval
                SetupWizardDeployCallback.clearStoredResult(deploymentId);
                return status;
            }

            // ── Tier 2: Query CMDT record as fallback ───────────────────
            // Handles case where Platform Cache is unavailable or partition
            // is not configured (callback stored nothing).
            String soql = 'SELECT Id, DeveloperName FROM Routing_Config__mdt '
                + 'WHERE DeveloperName = :devName LIMIT 1';
            Map<String, Object> binds = new Map<String, Object>{
                'devName' => deploymentId
            };

            List<SObject> results = Database.queryWithBinds(
                soql, binds, AccessLevel.USER_MODE
            );

            if (!results.isEmpty()) {
                status.done = true;
                status.success = true;
                status.status = 'Succeeded';
                return status;
            }

            // Neither callback result nor CMDT found — still deploying
            status.done = false;
            status.success = false;
            status.status = 'InProgress';
            return status;

        } catch (Exception ex) {
            status.done = true;
            status.success = false;
            status.errorMessage = String.format(
                System.Label.URE_WIZARD_DEPLOY_CHECK_ERROR, new List<Object>{ex.getMessage()}
            );
        }

        return status;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DTOs for deploy operations
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @description Result of deployConfig() containing the async deployment ID.
     */
    public class DeployResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String deploymentId;
        @AuraEnabled public String message;
        @AuraEnabled public String agentWarning;
    }

    /**
     * @description Result of getDeployStatus() for polling.
     */
    public class DeployStatusResult {
        @AuraEnabled public Boolean done;
        @AuraEnabled public Boolean success;
        @AuraEnabled public String status;
        @AuraEnabled public String errorMessage;
    }

    /**
     * @description Deserialized wizard state from the parent LWC.
     *              JSON structure matches the wizardState @track property.
     */
    public class WizardState {
        public String objectApiName;
        public String configLabel;
        public String configDevName;
        public String ownerFieldApiName;
        public String slaDeadlineField;
        public Integer maxCapacity;
        public Integer priorityWeight;
        public String assignmentField;
        public Boolean includeBusyAgents;
        public String deferResetField;
        public String deferResetValue;
        public List<WizardCondition> conditions;
        public List<WizardAgent> agents;
    }

    /**
     * @description Condition row from Step 3.
     */
    public class WizardCondition {
        public String fieldApiName;
        public String operator;
        public String values;
        public String valueType;
    }

    /**
     * @description Agent entry from Step 4.
     */
    public class WizardAgent {
        public Id userId;
        public List<String> skillValues;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Private helpers
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @description Validates required wizard state fields before deployment.
     */
    private static void validateWizardState(WizardState state) {
        List<String> errors = new List<String>();

        if (String.isBlank(state.objectApiName)) {
            errors.add(System.Label.URE_WIZARD_OBJECT_REQUIRED);
        }
        if (String.isBlank(state.configLabel)) {
            errors.add(System.Label.URE_WIZARD_CONFIG_NAME_REQUIRED);
        }
        if (String.isBlank(state.configDevName)) {
            errors.add(System.Label.URE_WIZARD_CONFIG_DEVNAME_REQUIRED);
        }
        if (String.isBlank(state.ownerFieldApiName)) {
            errors.add(System.Label.URE_WIZARD_OWNER_FIELD_REQUIRED);
        }

        if (!errors.isEmpty()) {
            throw new AuraHandledException(
                String.format(System.Label.URE_WIZARD_MISSING_FIELDS, new List<Object>{String.join(errors, ' ')})
            );
        }

        // Validate SObject exists and is accessible
        Schema.SObjectType sobjType = Schema.getGlobalDescribe().get(state.objectApiName);
        if (sobjType == null || !sobjType.getDescribe().isAccessible()) {
            throw new AuraHandledException(
                String.format(System.Label.URE_WIZARD_SOBJECT_NOT_ACCESSIBLE,
                    new List<Object>{String.escapeSingleQuotes(state.objectApiName)})
            );
        }
    }

    /**
     * @description Builds a Metadata.CustomMetadata record for Routing_Config__mdt.
     */
    private static Metadata.CustomMetadata buildConfigMetadata(WizardState state) {
        Metadata.CustomMetadata cm = new Metadata.CustomMetadata();
        cm.fullName = 'Routing_Config__mdt.' + state.configDevName;
        cm.label = truncateLabel(state.configLabel);

        addMetadataValue(cm, 'Object_API_Name__c', state.objectApiName);
        addMetadataValue(cm, 'Owner_Field_API_Name__c', state.ownerFieldApiName);
        addMetadataValue(cm, 'Active__c', true);

        if (state.slaDeadlineField != null) {
            addMetadataValue(cm, 'SLA_Deadline_Field__c', state.slaDeadlineField);
        }
        if (state.maxCapacity != null) {
            addMetadataValue(cm, 'Max_Capacity__c', state.maxCapacity);
        }
        if (state.priorityWeight != null) {
            addMetadataValue(cm, 'Priority_Weight__c', state.priorityWeight);
        }
        if (state.assignmentField != null) {
            addMetadataValue(cm, 'Assignment_Field__c', state.assignmentField);
        }
        if (state.includeBusyAgents != null) {
            addMetadataValue(cm, 'Include_Busy_Agents__c', state.includeBusyAgents);
        }
        if (state.deferResetField != null) {
            addMetadataValue(cm, 'Defer_Reset_Field__c', state.deferResetField);
        }
        if (state.deferResetValue != null) {
            addMetadataValue(cm, 'Defer_Reset_Value__c', state.deferResetValue);
        }

        return cm;
    }

    /**
     * @description Builds a Metadata.CustomMetadata record for Routing_Condition__mdt.
     */
    private static Metadata.CustomMetadata buildConditionMetadata(
        WizardState state,
        WizardCondition condition,
        Integer sortOrder
    ) {
        // Generate a unique DeveloperName from config name + field
        String conditionDevName = state.configDevName + '_'
            + condition.fieldApiName.replace('__c', '').replace('__r', '');

        // Ensure unique by appending sort order if needed
        conditionDevName = conditionDevName + '_' + sortOrder;

        // Sanitize: DeveloperName allows alphanumeric + underscore, max 40 chars
        conditionDevName = conditionDevName.replaceAll('[^a-zA-Z0-9_]', '_');
        if (conditionDevName.length() > 40) {
            conditionDevName = conditionDevName.substring(0, 40);
        }

        Metadata.CustomMetadata cm = new Metadata.CustomMetadata();
        cm.fullName = 'Routing_Condition__mdt.' + conditionDevName;
        cm.label = truncateLabel(state.configLabel + ' - ' + condition.fieldApiName);

        addMetadataValue(cm, 'Field_API_Name__c', condition.fieldApiName);
        addMetadataValue(cm, 'Operator__c', condition.operator);
        addMetadataValue(cm, 'Values__c', condition.values);
        addMetadataValue(cm, 'Is_Active__c', true);
        addMetadataValue(cm, 'Sort_Order__c', sortOrder);

        if (String.isNotBlank(condition.valueType)) {
            addMetadataValue(cm, 'Value_Type__c', condition.valueType);
        }

        // Set the parent relationship to Routing_Config__mdt
        // MetadataRelationship value = DeveloperName only — the platform
        // auto-resolves the entity prefix (Routing_Config.<DeveloperName>).
        // Passing 'Routing_Config__mdt.X' caused: "no CustomMetadata named
        // Routing_Config.Routing_Config__mdt.X found" (double-prefixed).
        addMetadataValue(cm, 'Routing_Config__c', state.configDevName);

        return cm;
    }

    /**
     * @description Adds a typed field value to a Metadata.CustomMetadata record.
     */
    private static void addMetadataValue(
        Metadata.CustomMetadata cm,
        String fieldName,
        Object value
    ) {
        Metadata.CustomMetadataValue fieldValue = new Metadata.CustomMetadataValue();
        fieldValue.field = fieldName;
        fieldValue.value = value;
        cm.values.add(fieldValue);
    }

    // Agent DML has been moved to SetupWizardDeployCallback.createAgentRecords()
    // to ensure atomicity: Agent__c records are only created after CMDT
    // deployment succeeds in the async callback.

    /**
     * @description Truncates a CMDT label to the platform maximum of 40 characters.
     *              Prevents async deployment failures caused by oversized labels
     *              (e.g. condition label = configLabel + ' - ' + fieldApiName).
     */
    private static String truncateLabel(String label) {
        if (label == null) { return ''; }
        return (label.length() > 40) ? label.substring(0, 40) : label;
    }

    /**
     * @description Determines if a field is a system/internal field that should
     *              be excluded from routing condition field picklists.
     */
    private static Boolean isSystemField(Schema.DescribeFieldResult fieldDesc) {
        String name = fieldDesc.getName().toLowerCase();

        // Skip standard system audit fields
        Set<String> systemFields = new Set<String>{
            'id', 'createdbyid', 'lastmodifiedbyid', 'systemmodstamp',
            'isdeleted', 'lastvieweddate', 'lastreferenceddate',
            'masterrecordid', 'connectionreceivedid', 'connectionsentid'
        };

        if (systemFields.contains(name)) {
            return true;
        }

        // Skip compound address/geolocation fields
        if (fieldDesc.getType() == Schema.DisplayType.ADDRESS
            || fieldDesc.getType() == Schema.DisplayType.LOCATION) {
            return true;
        }

        return false;
    }

    /**
     * @description Extracts picklist values for Picklist/MultiSelectPicklist fields.
     *              Returns null for non-picklist fields.
     */
    private static List<PicklistOption> getPicklistValues(
        Schema.DescribeFieldResult fieldDesc
    ) {
        if (fieldDesc.getType() != Schema.DisplayType.PICKLIST
            && fieldDesc.getType() != Schema.DisplayType.MULTIPICKLIST) {
            return null;
        }

        List<PicklistOption> options = new List<PicklistOption>();
        for (Schema.PicklistEntry entry : fieldDesc.getPicklistValues()) {
            if (entry.isActive()) {
                PicklistOption opt = new PicklistOption();
                opt.label = entry.getLabel();
                opt.value = entry.getValue();
                options.add(opt);
            }
        }
        return options;
    }
}
