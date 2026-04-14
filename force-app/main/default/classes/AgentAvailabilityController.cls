/**
 * @description Layer 3 -- AuraEnabled controller for agent availability status updates.
 *              Secure, validated endpoint for LWC components to change Availability_Status__c.
 * @group Entry
 */
public with sharing class AgentAvailabilityController {

    private static final Set<String> VALID_STATUSES = new Set<String>{
        'Online', 'Busy', 'Away', 'Offline'
    };

    /** @description Updates agent availability status and publishes a STATUS_CHANGE Platform Event. */
    @AuraEnabled
    public static String updateAgentStatus(Id agentId, String status) {
        if (String.isBlank(status) || !VALID_STATUSES.contains(status)) {
            throw new AuraHandledException(
                String.format(System.Label.URE_AVAIL_INVALID_STATUS, new List<Object>{status})
            );
        }

        if (agentId == null) {
            throw new AuraHandledException(System.Label.URE_AVAIL_AGENT_REQUIRED);
        }

        Agent__c agent = new Agent__c(
            Id = agentId,
            Availability_Status__c = status,
            Status_Last_Changed__c = Datetime.now()
        );

        Database.SaveResult sr = Database.update(agent, false, AccessLevel.USER_MODE);

        if (!sr.isSuccess()) {
            String errors = '';
            for (Database.Error err : sr.getErrors()) {
                errors += err.getMessage() + '; ';
            }
            throw new AuraHandledException(
                String.format(System.Label.URE_AVAIL_UPDATE_FAILED, new List<Object>{errors})
            );
        }

        try {
            Routing_Event__e evt = new Routing_Event__e(
                Event_Type__c = 'STATUS_CHANGE',
                Assigned_To__c = String.valueOf(agentId),
                Status__c = status,
                Routed_At__c = Datetime.now()
            );
            Database.SaveResult evtResult = EventBus.publish(evt);
            if (!evtResult.isSuccess()) {
                Logger.warn('STATUS_CHANGE event publish failed for agent=' + agentId)
                    .category(Logger.Category.ENGINE)
                    .inClass('AgentAvailabilityController')
                    .inMethod('updateAgentStatus')
                    .log();
            }
        } catch (Exception ex) {
            Logger.warn('STATUS_CHANGE event exception | ' + ex.getMessage())
                .category(Logger.Category.ENGINE)
                .inClass('AgentAvailabilityController')
                .inMethod('updateAgentStatus')
                .log();
        }

        return 'OK';
    }
}
