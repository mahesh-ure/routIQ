/**
 * ═══════════════════════════════════════════════════════════════════════════════
 * routIQ v6 — Sample Data Setup Script (Skill Bundle Architecture)
 * ═══════════════════════════════════════════════════════════════════════════════
 *
 * Creates sample operational data for the Skill Bundle pattern:
 *   - 5 Agents (Support L1, Support L2, Sales Rep, Senior Sales, Hybrid)
 *   - 7 Skill Bundles (3 Case, 2 Opp, 1 Common Case, 1 Cross-cutting)
 *   - Skill Bundle Entries per bundle
 *   - Agent Skill Assignments (agent ↔ bundle M:N)
 *   - 15 Test Cases (Support + Sales RecordTypes, with Target_Date__c)
 *   - 10 Test Opportunities
 *
 * Prerequisites (deploy metadata first):
 *   - Agent_Skill__mdt records: Case_Origin, Case_Priority, Case_Type, Opp_Stage
 *   - Routing_Config__mdt: Case_Support_Routing, Case_Sales_Routing, Opportunity_Routing
 *   - Case RecordTypes: Support, Sales
 *   - Case custom field: Target_Date__c
 *
 * Run via:
 *   sf apex run --file scripts/setup_v6_sample_data.apex --target-org <alias>
 *
 * Safe to re-run: deletes existing sample data before inserting.
 * ═══════════════════════════════════════════════════════════════════════════════
 */

// ╔═══════════════════════════════════════════════════════════════════════════╗
// ║ Step 0: Clean Slate — Remove existing operational data                  ║
// ╚═══════════════════════════════════════════════════════════════════════════╝

List<Agent_Skill_Assignment__c> oldAssignments = [SELECT Id FROM Agent_Skill_Assignment__c LIMIT 10000];
if (!oldAssignments.isEmpty()) {
    delete oldAssignments;
    System.debug('Deleted ' + oldAssignments.size() + ' old Agent_Skill_Assignment__c');
}

List<Skill_Bundle__c> oldBundles = [SELECT Id FROM Skill_Bundle__c LIMIT 10000];
if (!oldBundles.isEmpty()) {
    delete oldBundles; // Cascade deletes Skill_Bundle_Entry__c (Master-Detail)
    System.debug('Deleted ' + oldBundles.size() + ' old Skill_Bundle__c (+ cascade entries)');
}

List<Agent__c> oldAgents = [SELECT Id FROM Agent__c LIMIT 10000];
if (!oldAgents.isEmpty()) {
    delete oldAgents;
    System.debug('Deleted ' + oldAgents.size() + ' old Agent__c');
}

System.debug('Clean slate ready.');

// ╔═══════════════════════════════════════════════════════════════════════════╗
// ║ Step 1: Create 5 Agents                                                 ║
// ║                                                                         ║
// ║ NOTE: In a scratch org we only have 1 user. In production, each agent   ║
// ║ maps to a unique User__c. For demo purposes, agents 2-5 have User__c   ║
// ║ set to null (unlinked) — assign real users before routing.              ║
// ╚═══════════════════════════════════════════════════════════════════════════╝

Id currentUserId = UserInfo.getUserId();

Agent__c agentSupportL1 = new Agent__c(
    User__c         = currentUserId,
    Is_Active__c    = true,
    Max_Capacity__c = 10,
    Current_Load__c = 0
);
Agent__c agentSupportL2 = new Agent__c(
    User__c         = null,   // Assign real user in production
    Is_Active__c    = true,
    Max_Capacity__c = 8,
    Current_Load__c = 0
);
Agent__c agentSalesRep = new Agent__c(
    User__c         = null,
    Is_Active__c    = true,
    Max_Capacity__c = 5,
    Current_Load__c = 0
);
Agent__c agentSeniorSales = new Agent__c(
    User__c         = null,
    Is_Active__c    = true,
    Max_Capacity__c = 12,
    Current_Load__c = 0
);
Agent__c agentHybrid = new Agent__c(
    User__c         = null,
    Is_Active__c    = true,
    Max_Capacity__c = 6,
    Current_Load__c = 0
);

List<Agent__c> agents = new List<Agent__c>{
    agentSupportL1, agentSupportL2, agentSalesRep, agentSeniorSales, agentHybrid
};
insert agents;

System.debug('Inserted 5 Agent__c records.');
for (Agent__c a : agents) {
    System.debug('  Agent: ' + a.Id + ' | Capacity: ' + a.Max_Capacity__c);
}

// ╔═══════════════════════════════════════════════════════════════════════════╗
// ║ Step 2: Create 7 Skill Bundles                                          ║
// ║                                                                         ║
// ║ Bundle Design:                                                          ║
// ║                                                                         ║
// ║ CASE BUNDLES                                                            ║
// ║ ┌─────────────────────┬──────────────────────────────────────────────┐   ║
// ║ │ Case Common         │ Shared by ALL case agents (all origins)     │   ║
// ║ │ Case Support L1     │ Low-priority support: Problem, Question     │   ║
// ║ │ Case Support L2     │ High-priority escalation: all types         │   ║
// ║ │ Case Sales Inbound  │ Pre-sales inquiries via Phone/Web           │   ║
// ║ └─────────────────────┴──────────────────────────────────────────────┘   ║
// ║                                                                         ║
// ║ OPP BUNDLES                                                             ║
// ║ ┌─────────────────────┬──────────────────────────────────────────────┐   ║
// ║ │ Opp Early Stage     │ Prospecting + Qualification                 │   ║
// ║ │ Opp Full Pipeline   │ All stages (senior sales)                   │   ║
// ║ └─────────────────────┴──────────────────────────────────────────────┘   ║
// ║                                                                         ║
// ║ CROSS-CUTTING                                                           ║
// ║ ┌─────────────────────┬──────────────────────────────────────────────┐   ║
// ║ │ Escalation Override │ Adds High priority to any agent's profile   │   ║
// ║ └─────────────────────┴──────────────────────────────────────────────┘   ║
// ╚═══════════════════════════════════════════════════════════════════════════╝

Skill_Bundle__c bundleCaseCommon = new Skill_Bundle__c(
    Bundle_Name__c    = 'Case Common',
    Description__c    = 'Shared baseline for all case-handling agents. Covers all standard origins.',
    Is_Active__c      = true,
    Object_Context__c = 'Case'
);

Skill_Bundle__c bundleSupportL1 = new Skill_Bundle__c(
    Bundle_Name__c    = 'Case Support L1',
    Description__c    = 'Tier 1 support — handles Medium/Low priority Problems and Questions.',
    Is_Active__c      = true,
    Object_Context__c = 'Case'
);

Skill_Bundle__c bundleSupportL2 = new Skill_Bundle__c(
    Bundle_Name__c    = 'Case Support L2',
    Description__c    = 'Tier 2 escalation — handles High priority across all case types.',
    Is_Active__c      = true,
    Object_Context__c = 'Case'
);

Skill_Bundle__c bundleSalesInbound = new Skill_Bundle__c(
    Bundle_Name__c    = 'Case Sales Inbound',
    Description__c    = 'Pre-sales case handling — Phone/Web inquiries and questions.',
    Is_Active__c      = true,
    Object_Context__c = 'Case'
);

Skill_Bundle__c bundleOppEarly = new Skill_Bundle__c(
    Bundle_Name__c    = 'Opp Early Stage',
    Description__c    = 'Early pipeline opportunities — Prospecting and Qualification.',
    Is_Active__c      = true,
    Object_Context__c = 'Opportunity'
);

Skill_Bundle__c bundleOppFull = new Skill_Bundle__c(
    Bundle_Name__c    = 'Opp Full Pipeline',
    Description__c    = 'Full pipeline coverage — all open stages for senior reps.',
    Is_Active__c      = true,
    Object_Context__c = 'Opportunity'
);

Skill_Bundle__c bundleEscalation = new Skill_Bundle__c(
    Bundle_Name__c    = 'Escalation Override',
    Description__c    = 'Cross-cutting bundle that adds High priority handling to any agent profile. Demonstrates UNION merge.',
    Is_Active__c      = true,
    Object_Context__c = 'Case'
);

List<Skill_Bundle__c> bundles = new List<Skill_Bundle__c>{
    bundleCaseCommon, bundleSupportL1, bundleSupportL2,
    bundleSalesInbound, bundleOppEarly, bundleOppFull, bundleEscalation
};
insert bundles;

System.debug('Inserted 7 Skill_Bundle__c records.');
for (Skill_Bundle__c b : bundles) {
    System.debug('  Bundle: ' + b.Id + ' | ' + b.Bundle_Name__c);
}

// ╔═══════════════════════════════════════════════════════════════════════════╗
// ║ Step 3: Create Skill Bundle Entries                                     ║
// ║                                                                         ║
// ║ Agent_Skill__mdt dimensions used:                                       ║
// ║   Case_Origin   — maps to Case.Origin                                  ║
// ║   Case_Priority — maps to Case.Priority                                ║
// ║   Case_Type     — maps to Case.Type                                    ║
// ║   Opp_Stage     — maps to Opportunity.StageName                        ║
// ╚═══════════════════════════════════════════════════════════════════════════╝

List<Skill_Bundle_Entry__c> entries = new List<Skill_Bundle_Entry__c>();

// ── Case Common: all origins (shared baseline) ──────────────────────────────
entries.add(new Skill_Bundle_Entry__c(
    Skill_Bundle__c = bundleCaseCommon.Id,
    Agent_Skill__c  = 'Case_Origin',
    Values__c       = 'Phone,Email,Web,Chat'
));

// ── Case Support L1: Medium/Low + Problem/Question ─────────────────────────
entries.add(new Skill_Bundle_Entry__c(
    Skill_Bundle__c = bundleSupportL1.Id,
    Agent_Skill__c  = 'Case_Priority',
    Values__c       = 'Medium,Low'
));
entries.add(new Skill_Bundle_Entry__c(
    Skill_Bundle__c = bundleSupportL1.Id,
    Agent_Skill__c  = 'Case_Type',
    Values__c       = 'Problem,Question'
));

// ── Case Support L2: High/Medium + all types ───────────────────────────────
entries.add(new Skill_Bundle_Entry__c(
    Skill_Bundle__c = bundleSupportL2.Id,
    Agent_Skill__c  = 'Case_Priority',
    Values__c       = 'High,Medium'
));
entries.add(new Skill_Bundle_Entry__c(
    Skill_Bundle__c = bundleSupportL2.Id,
    Agent_Skill__c  = 'Case_Type',
    Values__c       = 'Problem,Question,Feature Request'
));

// ── Case Sales Inbound: Phone/Web origins + Question type ──────────────────
entries.add(new Skill_Bundle_Entry__c(
    Skill_Bundle__c = bundleSalesInbound.Id,
    Agent_Skill__c  = 'Case_Origin',
    Values__c       = 'Phone,Web'
));
entries.add(new Skill_Bundle_Entry__c(
    Skill_Bundle__c = bundleSalesInbound.Id,
    Agent_Skill__c  = 'Case_Priority',
    Values__c       = 'High,Medium'
));
entries.add(new Skill_Bundle_Entry__c(
    Skill_Bundle__c = bundleSalesInbound.Id,
    Agent_Skill__c  = 'Case_Type',
    Values__c       = 'Question'
));

// ── Opp Early Stage: Prospecting + Qualification ───────────────────────────
entries.add(new Skill_Bundle_Entry__c(
    Skill_Bundle__c = bundleOppEarly.Id,
    Agent_Skill__c  = 'Opp_Stage',
    Values__c       = 'Prospecting,Qualification'
));

// ── Opp Full Pipeline: all open stages ─────────────────────────────────────
entries.add(new Skill_Bundle_Entry__c(
    Skill_Bundle__c = bundleOppFull.Id,
    Agent_Skill__c  = 'Opp_Stage',
    Values__c       = 'Prospecting,Qualification,Needs Analysis,Value Proposition,Proposal/Price Quote'
));

// ── Escalation Override: adds High priority (UNION merge demo) ─────────────
entries.add(new Skill_Bundle_Entry__c(
    Skill_Bundle__c = bundleEscalation.Id,
    Agent_Skill__c  = 'Case_Priority',
    Values__c       = 'High'
));

insert entries;

System.debug('Inserted ' + entries.size() + ' Skill_Bundle_Entry__c records.');

// ╔═══════════════════════════════════════════════════════════════════════════╗
// ║ Step 4: Create Agent Skill Assignments (M:N junction)                   ║
// ║                                                                         ║
// ║ Assignment Matrix:                                                      ║
// ║ ┌────────────────────┬────────┬────────┬────────┬────────┬────────┐     ║
// ║ │ Bundle             │ Supp.  │ Supp.  │ Sales  │ Senior │ Hybrid │     ║
// ║ │                    │  L1    │  L2    │  Rep   │ Sales  │        │     ║
// ║ ├────────────────────┼────────┼────────┼────────┼────────┼────────┤     ║
// ║ │ Case Common        │   ✓    │   ✓    │   ✓    │   ✓    │   ✓    │     ║
// ║ │ Case Support L1    │   ✓    │        │        │        │   ✓    │     ║
// ║ │ Case Support L2    │        │   ✓    │        │        │        │     ║
// ║ │ Case Sales Inbound │        │        │   ✓    │   ✓    │        │     ║
// ║ │ Opp Early Stage    │        │        │   ✓    │        │   ✓    │     ║
// ║ │ Opp Full Pipeline  │        │        │        │   ✓    │        │     ║
// ║ │ Escalation Override│        │   ✓    │        │        │   ✓    │     ║
// ║ └────────────────────┴────────┴────────┴────────┴────────┴────────┘     ║
// ║                                                                         ║
// ║ UNION Merge Demonstration:                                              ║
// ║                                                                         ║
// ║ Agent "Support L1" (bundles: Case Common + Support L1):                 ║
// ║   Case_Origin   = {Phone, Email, Web, Chat}  ← from Case Common        ║
// ║   Case_Priority = {Medium, Low}               ← from Support L1        ║
// ║   Case_Type     = {Problem, Question}          ← from Support L1        ║
// ║                                                                         ║
// ║ Agent "Hybrid" (bundles: Case Common + Support L1 + Opp Early           ║
// ║                         + Escalation Override):                          ║
// ║   Case_Origin   = {Phone, Email, Web, Chat}  ← Case Common             ║
// ║   Case_Priority = {Medium, Low, High}          ← Support L1 ∪ Override  ║
// ║   Case_Type     = {Problem, Question}          ← Support L1             ║
// ║   Opp_Stage     = {Prospecting, Qualification} ← Opp Early Stage       ║
// ╚═══════════════════════════════════════════════════════════════════════════╝

List<Agent_Skill_Assignment__c> assignments = new List<Agent_Skill_Assignment__c>();

// ── Agent: Support L1 → Case Common + Case Support L1 ──────────────────────
assignments.add(new Agent_Skill_Assignment__c(
    Agent__c        = agentSupportL1.Id,
    Skill_Bundle__c = bundleCaseCommon.Id,
    Is_Active__c    = true
));
assignments.add(new Agent_Skill_Assignment__c(
    Agent__c        = agentSupportL1.Id,
    Skill_Bundle__c = bundleSupportL1.Id,
    Is_Active__c    = true
));

// ── Agent: Support L2 → Case Common + Case Support L2 + Escalation ────────
assignments.add(new Agent_Skill_Assignment__c(
    Agent__c        = agentSupportL2.Id,
    Skill_Bundle__c = bundleCaseCommon.Id,
    Is_Active__c    = true
));
assignments.add(new Agent_Skill_Assignment__c(
    Agent__c        = agentSupportL2.Id,
    Skill_Bundle__c = bundleSupportL2.Id,
    Is_Active__c    = true
));
assignments.add(new Agent_Skill_Assignment__c(
    Agent__c        = agentSupportL2.Id,
    Skill_Bundle__c = bundleEscalation.Id,
    Is_Active__c    = true
));

// ── Agent: Sales Rep → Case Common + Case Sales Inbound + Opp Early ───────
assignments.add(new Agent_Skill_Assignment__c(
    Agent__c        = agentSalesRep.Id,
    Skill_Bundle__c = bundleCaseCommon.Id,
    Is_Active__c    = true
));
assignments.add(new Agent_Skill_Assignment__c(
    Agent__c        = agentSalesRep.Id,
    Skill_Bundle__c = bundleSalesInbound.Id,
    Is_Active__c    = true
));
assignments.add(new Agent_Skill_Assignment__c(
    Agent__c        = agentSalesRep.Id,
    Skill_Bundle__c = bundleOppEarly.Id,
    Is_Active__c    = true
));

// ── Agent: Senior Sales → Case Common + Sales Inbound + Opp Full ──────────
assignments.add(new Agent_Skill_Assignment__c(
    Agent__c        = agentSeniorSales.Id,
    Skill_Bundle__c = bundleCaseCommon.Id,
    Is_Active__c    = true
));
assignments.add(new Agent_Skill_Assignment__c(
    Agent__c        = agentSeniorSales.Id,
    Skill_Bundle__c = bundleSalesInbound.Id,
    Is_Active__c    = true
));
assignments.add(new Agent_Skill_Assignment__c(
    Agent__c        = agentSeniorSales.Id,
    Skill_Bundle__c = bundleOppFull.Id,
    Is_Active__c    = true
));

// ── Agent: Hybrid → Case Common + Support L1 + Opp Early + Escalation ─────
assignments.add(new Agent_Skill_Assignment__c(
    Agent__c        = agentHybrid.Id,
    Skill_Bundle__c = bundleCaseCommon.Id,
    Is_Active__c    = true
));
assignments.add(new Agent_Skill_Assignment__c(
    Agent__c        = agentHybrid.Id,
    Skill_Bundle__c = bundleSupportL1.Id,
    Is_Active__c    = true
));
assignments.add(new Agent_Skill_Assignment__c(
    Agent__c        = agentHybrid.Id,
    Skill_Bundle__c = bundleOppEarly.Id,
    Is_Active__c    = true
));
assignments.add(new Agent_Skill_Assignment__c(
    Agent__c        = agentHybrid.Id,
    Skill_Bundle__c = bundleEscalation.Id,
    Is_Active__c    = true
));

insert assignments;

System.debug('Inserted ' + assignments.size() + ' Agent_Skill_Assignment__c records.');

// ╔═══════════════════════════════════════════════════════════════════════════╗
// ║ Step 5: Create Test Cases (Support + Sales RecordTypes)                 ║
// ║                                                                         ║
// ║ Uses Target_Date__c for priority ordering (NULLS LAST).                ║
// ║ Some cases intentionally have null Target_Date__c to test NULLS LAST.  ║
// ╚═══════════════════════════════════════════════════════════════════════════╝

// Get RecordType Ids dynamically (namespace-safe)
Map<String, Id> caseRtMap = new Map<String, Id>();
for (RecordType rt : [
    SELECT Id, DeveloperName
    FROM RecordType
    WHERE SObjectType = 'Case'
      AND DeveloperName IN ('Support', 'Sales')
      AND IsActive = true
]) {
    caseRtMap.put(rt.DeveloperName, rt.Id);
}

Id supportRtId = caseRtMap.get('Support');
Id salesRtId   = caseRtMap.get('Sales');

if (supportRtId == null || salesRtId == null) {
    System.debug('WARNING: Case RecordTypes Support/Sales not found. '
        + 'Deploy metadata first. Skipping Case creation.');
} else {
    List<Case> cases = new List<Case>();

    // ── Support Cases (10 records) ──────────────────────────────────────────
    cases.add(new Case(
        RecordTypeId   = supportRtId,
        Subject        = 'Login failure — SSO redirect loop',
        Status         = 'New',
        Priority       = 'High',
        Origin         = 'Phone',
        Type           = 'Problem',
        Target_Date__c = Date.today().addDays(1),
        Description    = 'Support case: urgent login issue for enterprise customer.'
    ));
    cases.add(new Case(
        RecordTypeId   = supportRtId,
        Subject        = 'Billing discrepancy — duplicate charge Q1',
        Status         = 'New',
        Priority       = 'Medium',
        Origin         = 'Email',
        Type           = 'Problem',
        Target_Date__c = Date.today().addDays(3),
        Description    = 'Support case: billing team review required.'
    ));
    cases.add(new Case(
        RecordTypeId   = supportRtId,
        Subject        = 'Dashboard export timeout on large datasets',
        Status         = 'Working',
        Priority       = 'Medium',
        Origin         = 'Web',
        Type           = 'Feature Request',
        Target_Date__c = Date.today().addDays(7),
        Description    = 'Support case: feature improvement request.'
    ));
    cases.add(new Case(
        RecordTypeId   = supportRtId,
        Subject        = 'Password reset — account locked',
        Status         = 'New',
        Priority       = 'Low',
        Origin         = 'Chat',
        Type           = 'Question',
        Target_Date__c = Date.today().addDays(5),
        Description    = 'Support case: routine password assistance.'
    ));
    cases.add(new Case(
        RecordTypeId   = supportRtId,
        Subject        = 'API rate limit exceeded in batch sync',
        Status         = 'Escalated',
        Priority       = 'High',
        Origin         = 'Email',
        Type           = 'Problem',
        Target_Date__c = Date.today(),
        Description    = 'Support case: critical integration failure.'
    ));
    cases.add(new Case(
        RecordTypeId   = supportRtId,
        Subject        = 'Mobile app crash on iOS 18',
        Status         = 'New',
        Priority       = 'High',
        Origin         = 'Web',
        Type           = 'Problem',
        Target_Date__c = Date.today().addDays(2),
        Description    = 'Support case: widespread mobile issue.'
    ));
    cases.add(new Case(
        RecordTypeId   = supportRtId,
        Subject        = 'Report scheduling — cron syntax help',
        Status         = 'New',
        Priority       = 'Low',
        Origin         = 'Phone',
        Type           = 'Question',
        Target_Date__c = null,  // NULLS LAST test
        Description    = 'Support case: no deadline, general help.'
    ));
    cases.add(new Case(
        RecordTypeId   = supportRtId,
        Subject        = 'Data migration — legacy CSV import errors',
        Status         = 'Working',
        Priority       = 'Medium',
        Origin         = 'Email',
        Type           = 'Problem',
        Target_Date__c = Date.today().addDays(10),
        Description    = 'Support case: migration assistance.'
    ));
    cases.add(new Case(
        RecordTypeId   = supportRtId,
        Subject        = 'Permission set assignment — bulk update',
        Status         = 'New',
        Priority       = 'Low',
        Origin         = 'Web',
        Type           = 'Question',
        Target_Date__c = null,  // NULLS LAST test
        Description    = 'Support case: admin task, no urgency.'
    ));
    cases.add(new Case(
        RecordTypeId   = supportRtId,
        Subject        = 'Workflow email not triggering on update',
        Status         = 'Escalated',
        Priority       = 'Medium',
        Origin         = 'Phone',
        Type           = 'Problem',
        Target_Date__c = Date.today().addDays(2),
        Description    = 'Support case: automation broken.'
    ));

    // ── Sales Cases (5 records) ─────────────────────────────────────────────
    cases.add(new Case(
        RecordTypeId   = salesRtId,
        Subject        = 'Enterprise pricing inquiry — 500 seats',
        Status         = 'New',
        Priority       = 'High',
        Origin         = 'Phone',
        Type           = 'Question',
        Target_Date__c = Date.today().addDays(2),
        Description    = 'Sales case: large enterprise deal, urgent.'
    ));
    cases.add(new Case(
        RecordTypeId   = salesRtId,
        Subject        = 'Product demo request — healthcare vertical',
        Status         = 'New',
        Priority       = 'Medium',
        Origin         = 'Web',
        Type           = 'Question',
        Target_Date__c = Date.today().addDays(5),
        Description    = 'Sales case: demo scheduling.'
    ));
    cases.add(new Case(
        RecordTypeId   = salesRtId,
        Subject        = 'Custom integration feasibility — SAP connector',
        Status         = 'Working',
        Priority       = 'High',
        Origin         = 'Phone',
        Type           = 'Question',
        Target_Date__c = Date.today().addDays(3),
        Description    = 'Sales case: pre-sales technical validation.'
    ));
    cases.add(new Case(
        RecordTypeId   = salesRtId,
        Subject        = 'Renewal discussion — contract expiring Q2',
        Status         = 'New',
        Priority       = 'Medium',
        Origin         = 'Web',
        Type           = 'Question',
        Target_Date__c = Date.today().addDays(14),
        Description    = 'Sales case: renewal pipeline.'
    ));
    cases.add(new Case(
        RecordTypeId   = salesRtId,
        Subject        = 'Competitor comparison — feature matrix request',
        Status         = 'New',
        Priority       = 'Low',
        Origin         = 'Web',
        Type           = 'Question',
        Target_Date__c = null,  // NULLS LAST test
        Description    = 'Sales case: early research, no deadline.'
    ));

    insert cases;

    System.debug('Inserted ' + cases.size() + ' Case records (10 Support + 5 Sales).');
    for (Case c : cases) {
        System.debug('  Case: ' + c.Id + ' | ' + c.Subject
            + ' | RT=' + (c.RecordTypeId == supportRtId ? 'Support' : 'Sales')
            + ' | Priority=' + c.Priority
            + ' | TargetDate=' + c.Target_Date__c);
    }
}

// ╔═══════════════════════════════════════════════════════════════════════════╗
// ║ Step 6: Create Test Opportunities                                       ║
// ╚═══════════════════════════════════════════════════════════════════════════╝

List<Opportunity> opps = new List<Opportunity>();

opps.add(new Opportunity(
    Name        = 'Acme Corp — Enterprise License',
    StageName   = 'Prospecting',
    Amount      = 150000,
    CloseDate   = Date.today().addDays(60)
));
opps.add(new Opportunity(
    Name        = 'Beta Inc — Platform Expansion',
    StageName   = 'Qualification',
    Amount      = 75000,
    CloseDate   = Date.today().addDays(45)
));
opps.add(new Opportunity(
    Name        = 'Gamma Ltd — Needs Assessment',
    StageName   = 'Needs Analysis',
    Amount      = 200000,
    CloseDate   = Date.today().addDays(90)
));
opps.add(new Opportunity(
    Name        = 'Delta Systems — Value Prop Review',
    StageName   = 'Value Proposition',
    Amount      = 320000,
    CloseDate   = Date.today().addDays(30)
));
opps.add(new Opportunity(
    Name        = 'Epsilon Group — Quote Pending',
    StageName   = 'Proposal/Price Quote',
    Amount      = 500000,
    CloseDate   = Date.today().addDays(15)
));
opps.add(new Opportunity(
    Name        = 'Zeta Healthcare — Initial Contact',
    StageName   = 'Prospecting',
    Amount      = 45000,
    CloseDate   = Date.today().addDays(120)
));
opps.add(new Opportunity(
    Name        = 'Eta Retail — Discovery Call',
    StageName   = 'Qualification',
    Amount      = 90000,
    CloseDate   = Date.today().addDays(75)
));
opps.add(new Opportunity(
    Name        = 'Theta Finance — Compliance Module',
    StageName   = 'Needs Analysis',
    Amount      = 180000,
    CloseDate   = Date.today().addDays(50)
));
opps.add(new Opportunity(
    Name        = 'Iota Logistics — Pilot Program',
    StageName   = 'Prospecting',
    Amount      = 25000,
    CloseDate   = Date.today().addDays(90)
));
opps.add(new Opportunity(
    Name        = 'Kappa Education — Campus License',
    StageName   = 'Value Proposition',
    Amount      = 110000,
    CloseDate   = Date.today().addDays(40)
));

insert opps;

System.debug('Inserted ' + opps.size() + ' Opportunity records.');
for (Opportunity o : opps) {
    System.debug('  Opp: ' + o.Id + ' | ' + o.Name + ' | Stage=' + o.StageName
        + ' | Amount=' + o.Amount);
}

// ╔═══════════════════════════════════════════════════════════════════════════╗
// ║ Summary Report                                                          ║
// ╚═══════════════════════════════════════════════════════════════════════════╝

System.debug('');
System.debug('══════════════════════════════════════════════════════════════════');
System.debug('  routIQ v6 Sample Data — Setup Complete');
System.debug('══════════════════════════════════════════════════════════════════');
System.debug('');
System.debug('  OPERATIONAL DATA');
System.debug('  ────────────────────────────────────────────────────');
System.debug('  Agent__c                   : 5 records');
System.debug('  Skill_Bundle__c            : 7 records');
System.debug('  Skill_Bundle_Entry__c      : ' + entries.size() + ' records');
System.debug('  Agent_Skill_Assignment__c  : ' + assignments.size() + ' records');
System.debug('');
System.debug('  TEST WORK ITEMS');
System.debug('  ────────────────────────────────────────────────────');
System.debug('  Case (Support RT)          : 10 records');
System.debug('  Case (Sales RT)            : 5 records');
System.debug('  Opportunity                : 10 records');
System.debug('');
System.debug('  RECORD COUNT COMPARISON (v5 → v6)');
System.debug('  ────────────────────────────────────────────────────');
System.debug('  v5 flat model: 5 agents × 4 skills = 20 Agent_Capability_Value__c');
System.debug('  v6 bundles:    7 bundles + ' + entries.size() + ' entries + '
    + assignments.size() + ' assignments = '
    + (7 + entries.size() + assignments.size()) + ' total records');
System.debug('  At scale (5K agents): v5 = 20,000 records → v6 = ~5,016 assignments + 7 bundles');
System.debug('');
System.debug('  ROUTING CONFIGS (CMDT — deployed via metadata)');
System.debug('  ────────────────────────────────────────────────────');
System.debug('  Case_Support_Routing   : RT=Support, ORDER BY Priority ASC, Target_Date__c ASC NULLS LAST');
System.debug('  Case_Sales_Routing     : RT=Sales,   ORDER BY Target_Date__c ASC NULLS LAST');
System.debug('  Opportunity_Routing    : ORDER BY Amount DESC, CloseDate ASC');
System.debug('  Case_Routing           : DEACTIVATED (replaced by RT-specific configs)');
System.debug('');
System.debug('  UNION MERGE EXAMPLES');
System.debug('  ────────────────────────────────────────────────────');
System.debug('  Hybrid agent (4 bundles):');
System.debug('    Case_Origin   = {Phone,Email,Web,Chat}          ← Case Common');
System.debug('    Case_Priority = {Medium,Low} ∪ {High} = {Medium,Low,High}  ← L1 + Escalation');
System.debug('    Case_Type     = {Problem,Question}              ← Support L1');
System.debug('    Opp_Stage     = {Prospecting,Qualification}     ← Opp Early');
System.debug('');
System.debug('══════════════════════════════════════════════════════════════════');
