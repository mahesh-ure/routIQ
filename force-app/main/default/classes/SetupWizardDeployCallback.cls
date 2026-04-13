/**
 * @description Metadata.DeployCallback implementation for the Setup Wizard.
 *              Handles two responsibilities after CMDT deployment completes:
 *
 *              1. Error reporting — stores deployment errors in Platform Cache
 *                 so getDeployStatus() can return actionable messages instead of
 *                 a generic timeout.
 *
 *              2. Agent provisioning atomicity — creates Agent__c records ONLY
 *                 after CMDT deployment succeeds. This prevents orphaned Agent__c
 *                 records when Routing_Config__mdt deployment fails.
 *
 *              The callback receives configDevName and serialised agent data via
 *              constructor parameters. These are serialised with the callback instance
 *              and survive the async boundary.
 *
 *              Platform Cache key format: 'wiz_deploy_<configDevName>'
 *              Platform Cache partition:  'local.URE'
 *              TTL: 600 seconds (10 minutes — well beyond the 3-minute poll window)
 *
 * @group Controller
 */
public without sharing class SetupWizardDeployCallback implements Metadata.DeployCallback {

    private static final String CACHE_PARTITION = 'local.URE';
    private static final String CACHE_KEY_PREFIX = 'wiz_deploy_';
    private static final Integer CACHE_TTL_SECS = 600;
    private static final String CLS = 'SetupWizardDeployCallback';

    /** DeveloperName of the Routing_Config__mdt being deployed — used as cache key */
    private String configDevName;

    /** JSON-serialised List<AgentData> — agents to create on success */
    private String agentDataJson;

    /** Max capacity from wizard state — applied to new Agent__c records */
    private Integer maxCapacity;

    /**
     * @description Constructor — called by SetupWizardController.deployConfig().
     *
     * @param configDevName   DeveloperName of the routing config being deployed
     * @param agentDataJson   JSON array of AgentData wrappers (userId + skillValues)
     * @param maxCapacity     Default max capacity for new agents
     */
    public SetupWizardDeployCallback(
        String configDevName,
        String agentDataJson,
        Integer maxCapacity
    ) {
        this.configDevName = configDevName;
        this.agentDataJson = agentDataJson;
        this.maxCapacity = (maxCapacity != null) ? maxCapacity : 5;
    }

    /**
     * @description Platform callback — invoked asynchronously after
     *              Metadata.Operations.enqueueDeployment() completes.
     */
    public void handleResult(
        Metadata.DeployResult deployResult,
        Metadata.DeployCallbackContext context
    ) {
        if (deployResult.status == Metadata.DeployStatus.Succeeded) {
            handleSuccess();
        } else {
            handleFailure(deployResult);
        }
    }

    // ─── Success Path ──────────────────────────────────────────────────────

    private void handleSuccess() {
        // Store success status in cache for getDeployStatus() polling
        storeDeployResult(new DeployOutcome(true, 'Succeeded', null));

        // Create Agent__c records now that CMDT is confirmed
        if (String.isNotBlank(agentDataJson)) {
            try {
                createAgentRecords();
            } catch (Exception ex) {
                // CMDT deployed OK — agent DML failed. Store partial success.
                Logger.warn('Agent DML failed in deploy callback | ' + ex.getMessage())
                    .category(Logger.Category.CONFIG)
                    .inClass(CLS).inMethod('handleSuccess')
                    .withException(ex)
                    .log();

                storeDeployResult(new DeployOutcome(
                    true,
                    'Succeeded',
                    'Configuration deployed but agent records failed: ' + ex.getMessage()
                ));
            }
        }
    }

    // ─── Failure Path ──────────────────────────────────────────────────────

    private void handleFailure(Metadata.DeployResult deployResult) {
        String errorMsg = extractErrorMessages(deployResult);

        Logger.error('CMDT deployment failed | config=' + configDevName
                + ' | errors=' + errorMsg)
            .category(Logger.Category.CONFIG)
            .inClass(CLS).inMethod('handleFailure')
            .log();

        storeDeployResult(new DeployOutcome(false, 'Failed', errorMsg));
    }

    /**
     * @description Extracts human-readable error messages from the deploy result.
     */
    private String extractErrorMessages(Metadata.DeployResult deployResult) {
        List<String> errors = new List<String>();

        if (deployResult.details != null
            && deployResult.details.componentFailures != null
        ) {
            for (Metadata.DeployMessage msg : deployResult.details.componentFailures) {
                if (msg.problem != null) {
                    errors.add(msg.fullName + ': ' + msg.problem);
                }
            }
        }

        if (errors.isEmpty()) {
            errors.add('Deployment failed with status: ' + deployResult.status);
        }

        return String.join(errors, '; ');
    }

    // ─── Agent Provisioning ────────────────────────────────────────────────

    /**
     * @description Creates Agent__c records for wizard-selected users.
     *              Skips users who already have an Agent__c record (duplicate-safe).
     *              Uses USER_MODE for CRUD/FLS enforcement.
     */
    private void createAgentRecords() {
        List<AgentData> agents = (List<AgentData>) JSON.deserialize(
            agentDataJson, List<AgentData>.class
        );

        if (agents == null || agents.isEmpty()) {
            return;
        }

        // Collect user IDs
        Set<Id> userIds = new Set<Id>();
        for (AgentData ad : agents) {
            if (ad.userId != null) {
                userIds.add(ad.userId);
            }
        }

        if (userIds.isEmpty()) {
            return;
        }

        // Check for existing Agent__c records (duplicate-safe)
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

        // Create new Agent__c records for users without existing records
        List<Agent__c> newAgents = new List<Agent__c>();
        for (AgentData ad : agents) {
            if (ad.userId != null && !existingUserIds.contains(ad.userId)) {
                Agent__c newAgent = new Agent__c();
                newAgent.User__c = ad.userId;
                newAgent.Is_Active__c = true;
                newAgent.Max_Capacity__c = this.maxCapacity;
                newAgent.Current_Load__c = 0;
                newAgents.add(newAgent);
            }
        }

        if (!newAgents.isEmpty()) {
            Database.insert(newAgents, true, AccessLevel.USER_MODE);
        }
    }

    // ─── Platform Cache Helpers ────────────────────────────────────────────

    /**
     * @description Stores deploy outcome in Platform Cache for polling retrieval.
     *              Gracefully fails if cache partition is not available.
     */
    private void storeDeployResult(DeployOutcome outcome) {
        try {
            Cache.OrgPartition partition = Cache.Org.getPartition(CACHE_PARTITION);
            if (partition != null) {
                String cacheKey = CACHE_KEY_PREFIX + configDevName;
                partition.put(cacheKey, JSON.serialize(outcome), CACHE_TTL_SECS);
            }
        } catch (Exception ex) {
            // Non-fatal — cache storage is best-effort
        }
    }

    /**
     * @description Reads deploy outcome from Platform Cache. Called by
     *              SetupWizardController.getDeployStatus().
     *
     * @param configDevName DeveloperName of the config to check
     * @return DeployOutcome or null if not cached
     */
    public static DeployOutcome getStoredResult(String configDevName) {
        try {
            Cache.OrgPartition partition = Cache.Org.getPartition(CACHE_PARTITION);
            if (partition != null) {
                String cacheKey = CACHE_KEY_PREFIX + configDevName;
                String cached = (String) partition.get(cacheKey);
                if (cached != null) {
                    return (DeployOutcome) JSON.deserialize(cached, DeployOutcome.class);
                }
            }
        } catch (Exception ex) {
            // Non-fatal — fall through to CMDT query approach
        }
        return null;
    }

    /**
     * @description Clears cached deploy result after polling completes.
     *
     * @param configDevName DeveloperName of the config to clear
     */
    public static void clearStoredResult(String configDevName) {
        try {
            Cache.OrgPartition partition = Cache.Org.getPartition(CACHE_PARTITION);
            if (partition != null) {
                String cacheKey = CACHE_KEY_PREFIX + configDevName;
                partition.remove(cacheKey);
            }
        } catch (Exception ex) {
            // Non-fatal
        }
    }

    // ─── Inner Classes ─────────────────────────────────────────────────────

    /**
     * @description Serialisable deploy outcome stored in Platform Cache.
     */
    public class DeployOutcome {
        public Boolean success;
        public String status;
        public String errorMessage;

        public DeployOutcome(Boolean success, String status, String errorMessage) {
            this.success = success;
            this.status = status;
            this.errorMessage = errorMessage;
        }
    }

    /**
     * @description Minimal agent data wrapper for JSON serialisation across
     *              the async callback boundary. Mirrors WizardAgent fields.
     */
    public class AgentData {
        public Id userId;
        public List<String> skillValues;
    }
}
