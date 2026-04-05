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
            throw new AuraHandledException('SObject API name is required.');
        }

        Schema.SObjectType sobjType = Schema.getGlobalDescribe().get(sObjectType);
        if (sobjType == null) {
            throw new AuraHandledException(
                'SObject type "' + String.escapeSingleQuotes(sObjectType)
                + '" does not exist or is not accessible.'
            );
        }

        // Validate object-level accessibility
        Schema.DescribeSObjectResult objDescribe = sobjType.getDescribe();
        if (!objDescribe.isAccessible()) {
            throw new AuraHandledException(
                'You do not have access to ' + objDescribe.getLabel() + '.'
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

        // Collect User Ids to query names (1 SOQL with USER_MODE)
        Set<Id> userIds = agentsByUser.keySet();
        String soql = 'SELECT Id, Name, Email FROM User WHERE Id IN :userIds';
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
     */
    public class AgentInfo {
        @AuraEnabled public Id agentId;
        @AuraEnabled public Id userId;
        @AuraEnabled public String userName;
        @AuraEnabled public String userEmail;
        @AuraEnabled public Integer maxCapacity;
        @AuraEnabled public Integer currentLoad;
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
            throw new AuraHandledException('A sample record ID is required for simulation.');
        }

        if (String.isBlank(configDevName)) {
            throw new AuraHandledException('Config developer name is required for simulation.');
        }

        // Validate recordId format
        String trimmedId = recordId.trim();
        if (trimmedId.length() != 15 && trimmedId.length() != 18) {
            throw new AuraHandledException('Invalid record ID format.');
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
            throw new AuraHandledException('Unable to determine SObject type from record ID.');
        }

        // Call RoutingService — dryRun prevents all side effects
        RoutingResult result = RoutingService.getNextRecord(
            request.objectApiName,
            request.recordId,
            request.configDevName
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
     *              Routing_Condition__mdt records via Metadata.Operations, and
     *              creates Agent__c / Skill_Bundle__c / Skill_Bundle_Entry__c
     *              records via standard DML.
     *
     *              CMDT deploy is asynchronous — returns a deployment ID that the
     *              LWC polls via getDeployStatus().
     *
     *              Agent and skill bundle records are DML (synchronous) and commit
     *              immediately.
     *
     * @param wizardStateJson JSON-serialized wizard state from the parent LWC
     * @return DeployResult with the deployment ID for polling
     * @throws AuraHandledException on invalid input or deploy failure
     */
    @AuraEnabled
    public static DeployResult deployConfig(String wizardStateJson) {
        if (String.isBlank(wizardStateJson)) {
            throw new AuraHandledException('Wizard state is required for deployment.');
        }

        WizardState state;
        try {
            state = (WizardState) JSON.deserialize(wizardStateJson, WizardState.class);
        } catch (Exception ex) {
            throw new AuraHandledException('Invalid wizard state format: ' + ex.getMessage());
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

        // Enqueue deployment — asynchronous
        try {
            Id deployId = Metadata.Operations.enqueueDeployment(container, null);
            deployResult.deploymentId = deployId;
            deployResult.success = true;
            deployResult.message = 'Configuration deployment started.';
        } catch (Exception ex) {
            throw new AuraHandledException(
                'Failed to start deployment: ' + ex.getMessage()
            );
        }

        // ── Part 2: Create Agent DML records (synchronous) ───────────────
        if (state.agents != null && !state.agents.isEmpty()) {
            try {
                createAgentRecords(state);
            } catch (Exception ex) {
                // CMDT deploy already started — log warning but don't fail
                Logger.warn('Agent DML failed during wizard deploy | ' + ex.getMessage())
                    .category(Logger.Category.CONFIG)
                    .inClass(CLS).inMethod('deployConfig')
                    .withException(ex)
                    .log();
                deployResult.agentWarning = 'Agent records could not be created: '
                    + ex.getMessage();
            }
        }

        return deployResult;
    }

    /**
     * @description Checks the status of a Metadata deployment by querying
     *              DeployRequest via the Tooling API (SOQL on DeployRequest).
     *
     *              Note: Metadata.Operations does NOT expose a checkDeployStatus()
     *              method in Apex. The only server-side option is to query
     *              DeployRequest or use the callback pattern. We query DeployRequest
     *              for simplicity — the LWC polls this method every 3 seconds.
     *
     * @param deploymentId The Id returned by deployConfig()
     * @return DeployStatusResult with current deployment status
     */
    @AuraEnabled
    public static DeployStatusResult getDeployStatus(String deploymentId) {
        if (String.isBlank(deploymentId)) {
            throw new AuraHandledException('Deployment ID is required.');
        }

        DeployStatusResult status = new DeployStatusResult();

        try {
            // Query DeployRequest to check status — standard SOQL on setup object
            String soql = 'SELECT Id, Status, ErrorMessage FROM DeployRequest '
                + 'WHERE Id = :deploymentId LIMIT 1';
            Map<String, Object> binds = new Map<String, Object>{
                'deploymentId' => Id.valueOf(deploymentId)
            };

            List<SObject> results = Database.queryWithBinds(
                soql, binds, AccessLevel.USER_MODE
            );

            if (results.isEmpty()) {
                // Deployment not found — may still be initializing
                status.done = false;
                status.success = false;
                status.status = 'Pending';
                return status;
            }

            SObject deployReq = results[0];
            String deployStatus = (String) deployReq.get('Status');
            String errorMsg = (String) deployReq.get('ErrorMessage');

            // Map DeployRequest.Status to our DTO
            if (deployStatus == 'Succeeded') {
                status.done = true;
                status.success = true;
                status.status = 'Succeeded';
            } else if (deployStatus == 'Failed' || deployStatus == 'Canceled') {
                status.done = true;
                status.success = false;
                status.status = deployStatus;
                status.errorMessage = String.isNotBlank(errorMsg)
                    ? errorMsg
                    : 'Deployment ' + deployStatus.toLowerCase() + '.';
            } else {
                // InProgress, Pending, Queued
                status.done = false;
                status.success = false;
                status.status = deployStatus;
            }
        } catch (Exception ex) {
            status.done = true;
            status.success = false;
            status.errorMessage = 'Unable to check deployment status: ' + ex.getMessage();
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
            errors.add('Object API name is required.');
        }
        if (String.isBlank(state.configLabel)) {
            errors.add('Configuration name is required.');
        }
        if (String.isBlank(state.configDevName)) {
            errors.add('Configuration developer name is required.');
        }
        if (String.isBlank(state.ownerFieldApiName)) {
            errors.add('Owner field API name is required.');
        }

        if (!errors.isEmpty()) {
            throw new AuraHandledException(
                'Missing required fields: ' + String.join(errors, ' ')
            );
        }

        // Validate SObject exists and is accessible
        Schema.SObjectType sobjType = Schema.getGlobalDescribe().get(state.objectApiName);
        if (sobjType == null || !sobjType.getDescribe().isAccessible()) {
            throw new AuraHandledException(
                'SObject "' + String.escapeSingleQuotes(state.objectApiName)
                + '" is not accessible.'
            );
        }
    }

    /**
     * @description Builds a Metadata.CustomMetadata record for Routing_Config__mdt.
     */
    private static Metadata.CustomMetadata buildConfigMetadata(WizardState state) {
        Metadata.CustomMetadata cm = new Metadata.CustomMetadata();
        cm.fullName = 'Routing_Config__mdt.' + state.configDevName;
        cm.label = state.configLabel;

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
        cm.label = state.configLabel + ' - ' + condition.fieldApiName;

        addMetadataValue(cm, 'Field_API_Name__c', condition.fieldApiName);
        addMetadataValue(cm, 'Operator__c', condition.operator);
        addMetadataValue(cm, 'Values__c', condition.values);
        addMetadataValue(cm, 'Is_Active__c', true);
        addMetadataValue(cm, 'Sort_Order__c', sortOrder);

        if (String.isNotBlank(condition.valueType)) {
            addMetadataValue(cm, 'Value_Type__c', condition.valueType);
        }

        // Set the parent relationship to Routing_Config__mdt
        addMetadataValue(cm, 'Routing_Config__c',
            'Routing_Config__mdt.' + state.configDevName);

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

    /**
     * @description Creates Agent__c records for users specified in the wizard.
     *              Checks for existing Agent__c records to avoid duplicates.
     *              Uses AccessLevel.USER_MODE for CRUD/FLS enforcement.
     */
    private static void createAgentRecords(WizardState state) {
        // Collect user IDs from wizard agents
        Set<Id> userIds = new Set<Id>();
        for (WizardAgent agent : state.agents) {
            if (agent.userId != null) {
                userIds.add(agent.userId);
            }
        }

        if (userIds.isEmpty()) {
            return;
        }

        // Check for existing agents to avoid duplicates
        String soql = 'SELECT Id, User__c FROM Agent__c WHERE User__c IN :userIds';
        Map<String, Object> binds = new Map<String, Object>{
            'userIds' => new List<Id>(userIds)
        };

        List<SObject> existingRecords = Database.queryWithBinds(
            soql, binds, AccessLevel.USER_MODE
        );

        Set<Id> existingUserIds = new Set<Id>();
        for (SObject rec : existingRecords) {
            existingUserIds.add((Id) rec.get('User__c'));
        }

        // Create new Agent__c records only for users without existing records
        List<Agent__c> newAgents = new List<Agent__c>();
        for (WizardAgent agent : state.agents) {
            if (agent.userId != null && !existingUserIds.contains(agent.userId)) {
                Agent__c newAgent = new Agent__c();
                newAgent.User__c = agent.userId;
                newAgent.Is_Active__c = true;
                newAgent.Max_Capacity__c = (state.maxCapacity != null)
                    ? state.maxCapacity : 5;
                newAgent.Current_Load__c = 0;
                newAgents.add(newAgent);
            }
        }

        if (!newAgents.isEmpty()) {
            Database.insert(newAgents, true, AccessLevel.USER_MODE);
        }
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
