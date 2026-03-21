/**
 * Agent Setup Script — creates Agent__c record for the current user
 * and links capability values for Case and Opportunity routing.
 *
 * Safe to re-run: uses upsert-by-User__c pattern.
 */

// ── Step 1: Create/Update Agent record ──────────────────────────────────────
Id currentUserId = UserInfo.getUserId();

// Check if agent already exists
List<Agent__c> existing = [
    SELECT Id, User__c, Is_Active__c, Max_Capacity__c, Current_Load__c
    FROM Agent__c
    WHERE User__c = :currentUserId
    LIMIT 1
];

Agent__c agent;
if (!existing.isEmpty()) {
    agent = existing[0];
    agent.Is_Active__c = true;
    agent.Max_Capacity__c = 10;
    agent.Current_Load__c = 0;   // Reset for testing
    update agent;
    System.debug('Agent updated: ' + agent.Id);
} else {
    agent = new Agent__c(
        User__c        = currentUserId,
        Is_Active__c   = true,
        Max_Capacity__c = 10,
        Current_Load__c = 0
    );
    insert agent;
    System.debug('Agent created: ' + agent.Id);
}

// ── Step 2: Create Agent Capability Values ──────────────────────────────────
// Delete existing values for clean slate
List<Agent_Capability_Value__c> oldValues = [
    SELECT Id FROM Agent_Capability_Value__c
    WHERE Agent__c = :agent.Id
];
if (!oldValues.isEmpty()) {
    delete oldValues;
    System.debug('Deleted ' + oldValues.size() + ' old capability values');
}

// Case_Origin capability — matches Case.Origin field values
// These are the origins our Case_Routing config filters on
Agent_Capability_Value__c caseOriginCap = new Agent_Capability_Value__c(
    Agent__c            = agent.Id,
    Agent_Capability__c = 'Case_Origin',
    Values__c           = 'Phone,Email,Web'
);

// Case_Priority capability — matches Case.Priority field values
Agent_Capability_Value__c casePriorityCap = new Agent_Capability_Value__c(
    Agent__c            = agent.Id,
    Agent_Capability__c = 'Case_Priority',
    Values__c           = 'High,Medium'
);

// Opp_Stage capability — matches Opportunity.StageName field values
Agent_Capability_Value__c oppStageCap = new Agent_Capability_Value__c(
    Agent__c            = agent.Id,
    Agent_Capability__c = 'Opp_Stage',
    Values__c           = 'Prospecting,Qualification,Needs Analysis,Value Proposition'
);

List<Agent_Capability_Value__c> newValues = new List<Agent_Capability_Value__c>{
    caseOriginCap, casePriorityCap, oppStageCap
};
insert newValues;

System.debug('══════════════════════════════════════════════════');
System.debug('Agent Setup Complete');
System.debug('══════════════════════════════════════════════════');
System.debug('Agent Id:       ' + agent.Id);
System.debug('User:           ' + UserInfo.getName() + ' (' + currentUserId + ')');
System.debug('Is Active:      ' + agent.Is_Active__c);
System.debug('Max Capacity:   ' + agent.Max_Capacity__c);
System.debug('Current Load:   ' + agent.Current_Load__c);
System.debug('Capabilities:   3 values created');
System.debug('  - Case_Origin:   Phone, Email, Web');
System.debug('  - Case_Priority: High, Medium');
System.debug('  - Opp_Stage:     Prospecting, Qualification, Needs Analysis, Value Proposition');
System.debug('══════════════════════════════════════════════════');
