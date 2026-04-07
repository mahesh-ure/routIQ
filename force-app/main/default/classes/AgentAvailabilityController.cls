/**
 * @description Layer 3 — AuraEnabled controller for agent availability status
 *              updates. Provides a secure, validated endpoint for LWC components
 *              (e.g., Routing Console, Supervisor Dashboard) to change an agent's
 *              Availability_Status__c and publish a STATUS_CHANGE Platform Event.
 *
 *              Security: USER_MODE DML enforces CRUD/FLS. Validates picklist
 *              values server-side to prevent invalid status injection.
 *
 * @group Entry
 */
public with sharing class AgentAvailabilityController {

    private static final Set<String> VALID_STATUSES = new Set<String>{
        'Online', 'Busy', 'Away', 'Offline'
    };

    /**
     * @description Updates the agent's availability status and publishes a
     *              STATUS_CHANGE Platform Event for real-time subscribers.
     *
     * @param agentId  The Agent__c record Id to update
     * @param status   New status: Online, Busy, Away, or Offline
     * @return String  'OK' on success; error message on failure
     */
    @AuraEnabled
    public static String updateAgentStatus(Id agentId, String status) {
        // ── Validate status value ───────────────────────────────────────
        if (String.isBlank(status) || !VALID_STATUSES.contains(status)) {
            throw new AuraHandledException(
                'Invalid status "' + status + '". '
                + 'Valid values: Online, Busy, Away, Offline.'
            );
        }

        if (agentId == null) {
            throw new AuraHandledException('Agent Id is required.');
        }

        // ── Update Agent__c record (USER_MODE for FLS) ──────────────────
        Agent__c agent = new Agent__c(
            Id = agentId,
            Availability_Status__c = status,
            Status_Last_Changed__c = Datetime.now()
        );

        Database.SaveResult sr = Database.update(
            agent, false, AccessLevel.USER_MODE
        );

        if (!sr.isSuccess()) {
            String errors = '';
            for (Database.Error err : sr.getErrors()) {
                errors += err.getMessage() + '; ';
            }
            throw new AuraHandledException(
                'Failed to update agent status: ' + errors
            );
        }

        // ── Publish STATUS_CHANGE Platform Event ────────────────────────
        try {
            Routing_Event__e evt = new Routing_Event__e(
                Event_Type__c = 'STATUS_CHANGE',
                Assigned_To__c = String.valueOf(agentId),
                Status__c = status,
                Routed_At__c = Datetime.now()
            );
            Database.SaveResult evtResult = EventBus.publish(evt);
            if (!evtResult.isSuccess()) {
                Logger.warn('STATUS_CHANGE event publish failed for agent='
                        + agentId)
                    .category(Logger.Category.ENGINE)
                    .inClass('AgentAvailabilityController')
                    .inMethod('updateAgentStatus')
                    .log();
            }
        } catch (Exception ex) {
            // Non-fatal — status update already committed
            Logger.warn('STATUS_CHANGE event exception | ' + ex.getMessage())
                .category(Logger.Category.ENGINE)
                .inClass('AgentAvailabilityController')
                .inMethod('updateAgentStatus')
                .log();
        }

        return 'OK';
    }
}
