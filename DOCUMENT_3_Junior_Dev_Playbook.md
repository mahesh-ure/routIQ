# URE Setup Playbook: From Zero to Routing
**Version:** 6.0 (Skill Bundle Architecture)  
**Audience:** Junior Developer  
**Scope:** One agent, one task object, one RecordType, one field  
**Time:** ~30 minutes  
**Last Updated:** April 2026

---

## Executive Summary

By the end of this guide, you will have:

1. ✅ Created 1 Agent record (John)
2. ✅ Created 1 Skill Bundle (Support_Standard)
3. ✅ Created 1 Skill Bundle Entry (Language skill)
4. ✅ Assigned the bundle to John (Agent_Skill_Assignment)
5. ✅ Created 1 Routing Config CMDT (Task_Support_Routing)
6. ✅ Created 1 Routing Condition CMDT (Status filter)
7. ✅ Created 1 Routing Skill Mapping CMDT (Language match)
8. ✅ Created 1 Routing Priority CMDT (Sort by load)
9. ✅ Tested the "Next Best Action" button
10. ✅ Understood the gaps and tech debt

---

## Part 1: Preparation (Read This First!)

### Things You Need

1. **Salesforce Org** with URE managed package installed
2. **Admin User** (to create CMDT records)
3. **2 Test Users** (to act as agents)
4. **Access to Setup** (to create metadata)

### Key Difference: Managed Package vs Subscriber Setup

**Managed Package (ISV provides):**
- Agent_Skill__mdt (skill dimensions like Language, ProductLine)
- Agent__c, Skill_Bundle__c, Skill_Bundle_Entry__c (custom objects)
- Routing Engine Apex classes
- Lives in `force-app/main/default/`

**Subscriber Setup (You do in your org):**
- Agent records (John, Maria, etc.)
- Skill_Bundle records (Support_Standard, etc.)
- Agent_Skill_Assignment records (John → Support_Standard)
- Routing_Config__mdt, Routing_Condition__mdt, Routing_Priority__mdt (CMDT records)
- Work records (Task, Case, etc.)

---

## Part 2: Step-by-Step Setup

### STEP 1: Create Test Users

**Navigate to:** Setup → Users → New User

Create 2 test users:
```
User 1:
- First Name: John
- Last Name: Smith
- Email: john.smith@uretest.com
- Username: john.smith@uretest.com
- Profile: Standard User
[SAVE]

User 2:
- First Name: Maria
- Last Name: Garcia
- Email: maria.garcia@uretest.com
- Username: maria.garcia@uretest.com
- Profile: Standard User
[SAVE]
```

**⏱ Time:** 2 minutes

---

### STEP 2: Create Agent Records

**Navigate to:** App Launcher → Agent → New

```
RECORD 1: John's Agent
├─ User: John Smith (lookup)
├─ Is Active: ✓ (checked)
├─ Max Capacity: 5
├─ Current Load: 0
├─ Availability Status: Online
[SAVE]

RECORD 2: Maria's Agent
├─ User: Maria Garcia
├─ Is Active: ✓
├─ Max Capacity: 5
├─ Current Load: 0
├─ Availability Status: Online
[SAVE]
```

**Result:** You now have 2 agents in the system.

**⏱ Time:** 2 minutes

---

### STEP 3: Create Skill Bundle

**Navigate to:** App Launcher → Skill Bundle → New

```
Skill Bundle Record:
├─ Name: Support_Standard
├─ DeveloperName: Support_Standard (auto-fills)
├─ Is Active: ✓ (checked)
[SAVE]
```

**Result:** You have a template to add skills to.

**⏱ Time:** 1 minute

---

### STEP 4: Create Skill Bundle Entry

**Navigate to:** Skill Bundle → Support_Standard → Scroll to "Skill Bundle Entries" → New

```
Skill Bundle Entry:
├─ Skill Bundle: Support_Standard (auto-filled)
├─ Agent Skill: Language (lookup to Agent_Skill__mdt)
├─ Skill Values: en_US
[SAVE]
```

**Where to find Agent_Skill__mdt record:**
- Go to Setup → Custom Metadata Types → Manage Records → Agent_Skill
- You should see records like "Language", "ProductLine"
- Select "Language" in the lookup

**Result:** John and Maria can now handle Language=en_US work.

**⏱ Time:** 2 minutes

---

### STEP 5: Assign Skill Bundle to Agents

**Navigate to:** Agent → John Smith → Scroll to "Agent Skill Assignments" → New

```
ASSIGNMENT 1: John gets Support_Standard
├─ Agent: John Smith (auto-filled)
├─ Skill Bundle: Support_Standard (lookup)
├─ Is Active: ✓
[SAVE]

Then repeat for Maria:
ASSIGNMENT 2: Maria gets Support_Standard
├─ Agent: Maria Garcia
├─ Skill Bundle: Support_Standard
├─ Is Active: ✓
[SAVE]
```

**Result:** Both agents now have Language=en_US skill.

**⏱ Time:** 2 minutes

---

### STEP 6: Create Task Test Record

**Navigate to:** App Launcher → Task → New

Create a sample task to be routed:

```
Task Record:
├─ Subject: "Email follow-up"
├─ Due Date: Tomorrow
├─ Priority: Normal
├─ Status: Not Started
├─ Language__c: en_US (custom field)
[SAVE]

Note the Task Record ID: [copy it]
```

**⏱ Time:** 1 minute

---

### STEP 7: Create Routing Config CMDT

**Navigate to:** Setup → Custom Metadata Types → Manage Records → Routing_Config

Create a new record:

```
Developer Name: Task_Support_Routing

Tab 1: Details
├─ Active: ✓ (checked)
├─ Object API Name: Task
├─ Record Type Developer Name: [leave blank for this guide]
├─ Owner Field API Name: OwnerId
├─ Select Fields: Id, Subject, Status, Priority, Language__c
├─ Candidate Limit: 200
├─ Pre-Assignment Owner Type: Unassigned
├─ Max Retry Attempts: 3
├─ Priority Weight: 100
[SAVE RECORD]
```

**⏱ Time:** 2 minutes

---

### STEP 8: Create Routing Condition CMDT

**Navigate to:** Setup → Custom Metadata Types → Manage Records → Routing_Condition

Create a condition that filters for tasks:

```
Developer Name: Cond_Status

Tab 1: Details
├─ Routing Config: Task_Support_Routing (lookup)
├─ Is Active: ✓
├─ Field API Name: Status
├─ Operator: NOT_EQUALS
├─ Values: Completed
├─ Is Indexed: ✓
├─ Sort Order: 1
[SAVE RECORD]
```

**Translation:** "Only route tasks that are NOT Completed."

**⏱ Time:** 2 minutes

---

### STEP 9: Create Routing Skill Mapping CMDT

**Navigate to:** Setup → Custom Metadata Types → Manage Records → Routing_Skill_Mapping

Create a mapping that matches agent language to task language:

```
Developer Name: Match_Language

Tab 1: Details
├─ Routing Config: Task_Support_Routing (lookup)
├─ Agent Skill: Language (lookup to Agent_Skill__mdt)
├─ Work Record Field: Language__c
├─ Is Required: ✓ (checked)
├─ Operator: INCLUDES
[SAVE RECORD]
```

**Translation:** "Agent MUST have a Language skill that includes the task's Language__c value."

**⏱ Time:** 2 minutes

---

### STEP 10: Create Routing Priority CMDT

**Navigate to:** Setup → Custom Metadata Types → Manage Records → Routing_Priority

Create a priority that sorts by agent load:

```
Developer Name: Sort_Load

Tab 1: Details
├─ Routing Config: Task_Support_Routing (lookup)
├─ Is Active: ✓
├─ Field API Name: Current_Load__c
├─ Sort Direction: ASC
├─ Sort Order: 1
[SAVE RECORD]
```

**Translation:** "Sort agents by Current_Load ascending — agent with lowest load gets the task first."

**⏱ Time:** 1 minute

---

### STEP 11: Test Routing

**Step 11a: Log in as John**

1. Log out of admin account
2. Log in as John Smith (john.smith@uretest.com)
3. Go to **Utility Bar** → Find **URE Agent Work Panel** (or **Routing Console**)

**Step 11b: Click "Next Best Action"**

```
Expected Behavior:
│
├─ Button shows "Looking for next task..." (spinner)
│
├─ 2-3 seconds later...
│
├─ Message appears: "Task assigned! Email follow-up"
│
├─ Task is now assigned to John (Owner = John)
│
├─ John's Current_Load__c increments to 1
│
└─ Routing_Log__c record created with:
   ├─ Status: Success
   ├─ Assigned_To: John Smith
   ├─ Config_Developer_Name: Task_Support_Routing
   └─ Candidate_Count: 1
```

**Step 11c: Verify in Salesforce**

Go to Task record you created:
- Owner should now be **John Smith** ✓
- Status should still be **Not Started**

Check Routing_Log__c:
- App Launcher → Routing Log → Search for your task
- Status should be **Success**

**⏱ Time:** 5 minutes

---

## Part 3: Understanding the Data Flow

### What Just Happened

```
Click "Next Best Action"
    ↓
LWC calls RoutingService.getNextRecord(configDeveloperName='Task_Support_Routing')
    ↓
RoutingEngine.execute() — 6 Phases:
    │
    ├─ Phase 1: Validate request (objectApiName='Task') ✓
    ├─ Phase 2: Check John is active, online, has capacity ✓
    ├─ Phase 3: Load Task_Support_Routing config from CMDT ✓
    │
    ├─ Phase 4: Find Candidates
    │   ├─ Build SQL: SELECT Id, Subject FROM Task WHERE Status != 'Completed'
    │   ├─ Query returns your Task record
    │   ├─ Check: Does John have Language skill? ✓ (yes, en_US)
    │   ├─ Check: Does Task Language__c match John's? ✓ (both en_US)
    │   ├─ Lock the Task record FOR UPDATE
    │   ├─ Update Task.OwnerId = John
    │   ├─ Increment John.Current_Load__c (0 → 1)
    │   └─ Insert Routing_Log__c (Status=Success)
    │
    └─ Return: RoutingResult(success=true, recordId=..., recordName="Email follow-up")

    ↓
LWC shows: "Email follow-up assigned!"
    ↓
John's load increases, his queue depth shows +1 task
```

---

## Part 4: Gaps & Issues in URE (Technical Debt)

### 🔴 CRITICAL GAPS

#### 1. **Agent_Skill__mdt is NOT Org-Manageable**
**Status:** MAJOR ISSUE  
**Problem:** ISV (package developer) must define all skill dimensions in Agent_Skill__mdt before package is installed. End users cannot add new skills after installation.

**Impact:** If a subscriber needs a new skill like "SeniorityLevel" or "TeamRegion", they must contact ISV to create a package update.

**Why it exists:** Agent_Skill__mdt is part of the managed package (in `force-app/main/default/objects/`), so it's not editable by subscribers.

**Workaround (hacky):** Subscribers can create Agent_Skill__mdt records in "unpackaged" space via Org-Managed CMDT, but this requires manual metadata API work — not UI friendly.

**Fix needed:** Redesign Agent_Skill__mdt as an **org-managed CMDT** instead of managed package CMDT. This requires refactoring:
- Move Agent_Skill__mdt definition to `unpackaged/` (NOT `force-app/`)
- Update AgentCapabilitySelector to query dynamically instead of hardcoding skill names
- Document how subscribers can extend skills post-install

---

#### 2. **No Validation for Undefined Skills in Skill_Bundle_Entry**
**Status:** DATA INTEGRITY ISSUE  
**Problem:** When creating Skill_Bundle_Entry, there's no database-level validation that the Agent_Skill__c lookup is valid. If ISV hasn't created a "Geography" skill yet, but subscriber tries to add it, the lookup fails silently in the UI.

**Impact:** Confusing UX. Subscriber doesn't know if the skill doesn't exist or if it's a lookup error.

**Why it exists:** No trigger on Skill_Bundle_Entry__c to validate Agent_Skill__c.

**Fix needed:** Add trigger + custom validation:
```apex
// Skill_Bundle_Entry__c trigger
// Check: Agent_Skill__c must exist in Agent_Skill__mdt
// Check: Agent_Skill__c must have Is_Active__c = true
```

---

#### 3. **Missing Admin UI for Agent Availability Toggle**
**Status:** FUNCTIONAL GAP  
**Problem:** Agent.Availability_Status__c can only be updated programmatically. There's no Salesforce UI component for agents to toggle Online/Away/Busy/Offline.

**Impact:** Agents must use the LWC Utility Bar component, but if they don't have it on their page, they can't change availability. Admins must manually update records.

**Why it exists:** The LWC ureAgentWorkPanel has availability toggle, but it's not installed by default.

**Fix needed:**
- Create a **standalone "Availability Toggle" LWC component**
- Deploy it to record pages by default (Case, Task detail pages)
- Test in Flow so agents can self-serve availability changes

---

#### 4. **Routing_Log__c Doesn't Capture Query Bind Values (Security Risk)**
**Status:** OBSERVABILITY & SECURITY ISSUE  
**Problem:** When a routing query fails or has unexpected results, AuditLogger doesn't log the bind parameter values (e.g., what Status values were filtered, what Priority was matched). This makes troubleshooting very hard.

**Current:** Routing_Log__c only has `Record_Id__c`, `Status__c`, `Error_Message__c`. No query snapshot.

**Why it's a problem:** 
- Admins can't debug why a case wasn't routed
- No audit trail of which values were used in the query
- Security review may flag insufficient audit trails

**Fix needed:** Add field to Routing_Log__c:
```apex
Query_Bind_Snapshot__c (LongTextArea) — serialize the bind map as JSON
// Example: {"Status": ["Closed", "Cancelled"], "Priority": "High"}
```

---

### 🟡 MODERATE ISSUES

#### 5. **No Candidate Count Limit Enforcement**
**Status:** PERFORMANCE ISSUE  
**Problem:** Routing_Config__mdt.Candidate_Limit__c is a suggestion, not a hard limit. If 10,000 tasks match the query, CandidateSelector loads all 10,000 into memory, which can cause heap exhaustion.

**Current code:**
```apex
// DynamicQueryBuilder adds LIMIT, but if admin sets Candidate_Limit__c = 10000
List<SObject> candidates = CandidateSelector.query(spec);
// If 10,000 rows returned, this can OOM on large orgs
```

**Why it's a problem:**
- Large orgs with millions of records can crash the query
- No warning when query is about to exceed limits
- Governor limits (heap, CPU) can spike unexpectedly

**Fix needed:**
- Add safeguard in DynamicQueryBuilder:
  ```apex
  Integer limit = Math.min(
      (Integer) config.Candidate_Limit__c,
      200  // Hard cap
  );
  ```
- Log warning if > 100 candidates returned

---

#### 6. **Routing Conditions Don't Support Null Checks**
**Status:** FEATURE GAP  
**Problem:** Operators like `EQUALS`, `NOT_EQUALS` don't handle NULL values correctly.

**Example:** You want to route only Tasks where `Owner__c IS NULL`, but there's no Operator for NULL checks.

**Current Operators:**
- EQUALS, NOT_EQUALS, INCLUDES, EXCLUDES, GREATER_THAN, LESS_THAN, etc.
- No NULL check operator

**Why it's a problem:**
- Common use case (route unassigned records only)
- Workaround is clunky (filter by placeholder values)

**Fix needed:** Add operators:
- `IS_NULL`
- `IS_NOT_NULL`

---

#### 7. **No "Dry Run" UI for Testing Routing**
**Status:** TESTING GAP  
**Problem:** RoutingService has a `dryRun` parameter that executes routing without side effects (no DML, no Routing_Log). But there's no LWC component that uses it.

**Why it's useful:** Admins could test configs before going live.

**Current:** Only available via REST API or Flow. LWC doesn't expose the dryRun toggle.

**Fix needed:** Update ureRoutingSimulator (or create new component) to:
- Show "Dry Run" checkbox
- Call getNextRecord(dryRun=true)
- Display what WOULD have happened without committing changes
- Show the generated SOQL query

---

#### 8. **Agent Skills Are Additive (UNION) Only — No Exclusions**
**Status:** DESIGN LIMITATION  
**Problem:** When an agent has multiple Skill Bundles, skill values are always unioned (combined). There's no way to say "this agent should NOT handle billing cases" or create a negative filter.

**Example:**
- John has Bundle A: ProductLine={General, Billing}
- John has Bundle B: ProductLine={General, Support}
- **Result:** John's ProductLine = {General, Billing, Support}
- **Problem:** You wanted Bundle A to override (General + Billing only), not add Support

**Why it's a design choice:**
- UNION is simpler to implement and reason about
- Avoids precedence/override conflicts

**Workaround:** Use separate agents or bundles for different roles.

**Fix needed (if needed):** Add Skill_Bundle_Entry field:
```apex
Merge_Type__c: UNION (default) | REPLACE | EXCLUDE
// REPLACE: this bundle's values override previous ones
// EXCLUDE: remove these values from the set
```

---

### 🟢 NICE-TO-HAVE IMPROVEMENTS

#### 9. **Routing_Priority Sorting Happens in SOQL, Not Memory**
**Status:** DESIGN NOTE  
**Problem:** Candidates are sorted by Routing_Priority SOQL ORDER BY clause. If you need to sort by a calculated field (e.g., "agent with least load among those with specific skill"), you'd need post-query in-memory sorting.

**Current:** Sorting = SOQL ORDER BY only.

**Why it matters:** Advanced scenarios (multi-factor ranking) aren't supported.

**Fix (if needed):** Refactor AssignmentResolver to support in-memory candidate ranking after query.

---

#### 10. **No "Round-Robin" Assignment Strategy**
**Status:** FEATURE REQUEST  
**Problem:** Routing always picks the "best" candidate (lowest load). There's no option for round-robin (alternating between agents).

**Use case:** Some teams prefer fair rotation over load-based distribution.

**Fix (if needed):** Add Routing_Config field:
```apex
Assignment_Strategy__c: BEST_MATCH (default) | ROUND_ROBIN
```

---

#### 11. **Audit Logger Is Insert-Only — Can't Fix Bad Logs**
**Status:** DATA MGMT ISSUE  
**Problem:** Routing_Log__c records are never updated. If a log is created with wrong data, admins can't fix it — only delete it.

**Why it matters:** Compliance/audit trails require accurate, unfalsifiable records (hence insert-only). But bugs can still create wrong records.

**Fix (if needed):** Add read-only UI view that shows Routing_Log records with explanation of failures. Make it clear these are immutable.

---

## Part 5: Checklist & Next Steps

### Setup Completion Checklist

- [x] Created 2 test users (John, Maria)
- [x] Created 2 Agent records
- [x] Created 1 Skill Bundle (Support_Standard)
- [x] Created 1 Skill Bundle Entry (Language=en_US)
- [x] Created 2 Agent Skill Assignments
- [x] Created 1 Task record (test data)
- [x] Created Routing_Config__mdt (Task_Support_Routing)
- [x] Created Routing_Condition__mdt (Status filter)
- [x] Created Routing_Skill_Mapping__mdt (Language match)
- [x] Created Routing_Priority__mdt (Sort by load)
- [x] Tested "Next Best Action" button
- [x] Verified Task was assigned to John
- [x] Verified Routing_Log__c record created

---

### Extending This Setup

**Want to add a second task type (e.g., "Complex Tasks" for advanced agents)?**

1. Create new Agent_Skill_Assignment for advanced agents only (don't add them to Support_Standard)
2. Create new Skill_Bundle: "Advanced_Support"
3. Create new Skill Bundle Entry: ProductLine=Technical
4. Create new Routing_Config__mdt: Task_Technical_Routing
5. Create new Routing_Condition__mdt: Priority=High
6. Create new Routing_Skill_Mapping__mdt: ProductLine match
7. Create new Routing_Priority__mdt: Sort by Last_Assigned__c (prefer longer-waiting agents)

Both configs will run, and tasks will be routed to whichever config matches first.

---

## Part 6: Common Errors & Troubleshooting

### Error: "No active Agent record found"

**Cause:** John's Agent record has Is_Active__c = false, or User__c lookup is broken.

**Fix:**
1. Go to John's Agent record
2. Verify Is_Active__c is ✓ checked
3. Verify User__c lookup points to John Smith user
4. Verify John's user has an active license (not inactive)

---

### Error: "Agent at capacity"

**Cause:** John's Current_Load__c ≥ Max_Capacity__c.

**Fix:**
1. Go to John's Agent record
2. Check Current_Load__c (how many tasks does John have?)
3. Increase Max_Capacity__c to a higher number
4. OR mark some of John's old tasks as Completed so load decreases

---

### Error: "No routing configs match this record"

**Cause:**
- No Routing_Config__mdt for Task object
- OR Routing_Config is set to Active=false
- OR Record Type doesn't match config's Record_Type_Dev_Name

**Fix:**
1. Go to Setup → Custom Metadata Types → Manage Records → Routing_Config
2. Find Task_Support_Routing
3. Verify Active__c is ✓ checked
4. Verify Object_API_Name = Task
5. Verify Record_Type_Dev_Name is blank (unless you set it specifically)

---

### Error: "Agent does not have required skills"

**Cause:** John's Language skill doesn't include the task's Language__c value.

**Fix:**
1. Go to Task record
2. Check Language__c field (what language is it?)
3. Go to John's Agent record → Agent Skill Assignments → Support_Standard
4. Click Support_Standard Skill Bundle
5. Find the Language entry
6. Check Skill_Values: does it include that language?
7. If not, add it: en_US,es_MX (comma-separated)

---

### Error: "Task not assigned; no toast message"

**Cause:** Button click worked but something returned failure silently.

**Fix (Debug Mode):**
1. Open browser DevTools (F12)
2. Go to Console tab
3. Log in as John again
4. Click "Next Best Action" button
5. Look for JavaScript errors (red messages)
6. Check for Apex errors in logs:
   - Go to Setup → Apex Classes → Click RoutingService_Test
   - Look for recent test results

**Advanced Debug:**
1. Log in as Admin
2. Open Salesforce Dev Console (Ctrl+Shift+O)
3. Scroll through recent Apex logs
4. Filter for "RoutingService" or "RoutingEngine"
5. Look for exceptions or warnings

---

## Part 7: Data Schema Reference

### Agent__c

```
Field Name               | Type      | Required? | Notes
─────────────────────────┼───────────┼───────────┼─────────────
Id                       | ID        | System    | Salesforce ID
Name                     | Text      | Auto      | e.g., "Support Agent A"
User__c                  | Lookup    | YES       | Links to User
Is_Active__c             | Checkbox  | YES       | true/false
Max_Capacity__c          | Number    | NO        | e.g., 5 tasks
Current_Load__c          | Number    | NO        | e.g., 2 tasks (auto-incremented)
Availability_Status__c   | Picklist  | NO        | Online/Busy/Away/Offline
Last_Assigned__c         | DateTime  | NO        | Auto-set when task assigned
Status_Last_Changed__c   | DateTime  | NO        | When did status change?
```

---

### Routing_Config__mdt

```
Field Name                      | Type       | Notes
────────────────────────────────┼────────────┼─────────────
DeveloperName                   | Text       | Unique ID (e.g., Task_Support_Routing)
Active__c                       | Checkbox   | Is this config enabled?
Object_API_Name__c              | Text       | Task, Case, Lead, etc.
Record_Type_Dev_Name__c         | Text       | Optional; if specified, only this RecordType
Owner_Field_API_Name__c         | Text       | OwnerId (where to assign)
Select_Fields__c                | LongText   | Comma-separated field list for SELECT clause
Candidate_Limit__c              | Number     | LIMIT for query (e.g., 200)
Pre_Assignment_Owner_Type__c    | Picklist   | Unassigned / Null / Queue
Max_Retry_Attempts__c           | Number     | Lock retry count (e.g., 3)
Priority_Weight__c              | Number     | Higher = check this config first
```

---

### Routing_Condition__mdt

```
Field Name                | Type       | Notes
──────────────────────────┼────────────┼─────────────
DeveloperName             | Text       | Unique ID (e.g., Cond_Status)
Routing_Config__c         | Lookup     | Parent config
Is_Active__c              | Checkbox   | Is this condition active?
Field_API_Name__c         | Text       | Status, Priority, etc.
Operator__c               | Picklist   | EQUALS, NOT_EQUALS, INCLUDES, GREATER_THAN, etc.
Values__c                 | LongText   | Comma-separated values (e.g., High;Critical)
Condition_Group__c        | Number     | For OR logic (optional; null = AND)
Is_Indexed__c             | Checkbox   | Is this field indexed? (performance hint)
Sort_Order__c             | Number     | Order of evaluation (1, 2, 3...)
```

---

### Skill_Bundle__c

```
Field Name          | Type     | Notes
────────────────────┼──────────┼─────────────
Name                | Text     | e.g., Support_Standard
DeveloperName       | Text     | Unique ID (auto-fill)
Is_Active__c        | Checkbox | Is this bundle active?
```

---

### Agent_Skill_Assignment__c (Junction)

```
Field Name          | Type     | Notes
────────────────────┼──────────┼─────────────
Agent__c            | Lookup   | Which agent?
Skill_Bundle__c     | Lookup   | Which bundle?
Is_Active__c        | Checkbox | Is this assignment active?
```

---

### Routing_Log__c (Insert-Only Audit Table)

```
Field Name                  | Type      | Notes
─────────────────────────────┼───────────┼─────────────
Record_Id__c                | Text      | Which record was routed?
Config_Developer_Name__c    | Text      | Which config was used?
Assigned_To__c              | Lookup    | Which user got it?
Status__c                   | Picklist  | Success / No_Match / Locked / Error
Candidate_Count__c          | Number    | How many candidates matched?
Retry_Count__c              | Number    | Lock retries (0 = success on first try)
Error_Message__c            | Text      | Why did it fail?
Routed_At__c                | DateTime  | When?
Lock_Contention__c          | Checkbox  | Was there lock contention?
```

---

## Summary of Critical Gaps

| # | Title | Severity | Impact | Fix Effort |
|---|-------|----------|--------|-----------|
| 1 | Agent_Skill__mdt not org-editable | 🔴 HIGH | Users can't add new skill types | Medium |
| 2 | No validation for undefined skills | 🔴 HIGH | Data quality issues | Low |
| 3 | Missing availability UI | 🔴 HIGH | Agents can't change status | Low |
| 4 | Query binds not logged | 🔴 HIGH | Hard to troubleshoot | Low |
| 5 | No candidate limit enforcement | 🟡 MEDIUM | Can crash large orgs | Low |
| 6 | No NULL operators | 🟡 MEDIUM | Can't route nulls | Medium |
| 7 | No dry-run UI | 🟡 MEDIUM | Can't test before live | Medium |
| 8 | Skills only union, no exclude | 🟡 MEDIUM | Complex role modeling hard | High |
| 9 | In-memory sorting not supported | 🟢 LOW | Advanced use cases blocked | High |
| 10 | No round-robin strategy | 🟢 LOW | Only load-based assignment | Medium |
| 11 | Audit logs immutable forever | 🟢 LOW | Data cleanup hard | Medium |

---

## Next Steps

1. **Complete this playbook** ✓
2. **Read DOCUMENT_1** (Configuration Guide) for detailed metadata reference
3. **Read DOCUMENT_2** (Execution Flow) to understand how routing works internally
4. **Propose fixes** for the 11 gaps listed above to your team lead
5. **Create Jira/GitHub issues** for high-severity gaps (1-4)
6. **Start planning** Skill Bundle extensibility (Gap #1)

---

**Congratulations!** 🎉

You've successfully set up URE routing for a Task object with one agent. You now understand:
- How to configure routing metadata
- How the engine executes internally
- What technical debt exists in the codebase
- How to extend for new scenarios

Next: discuss with your team which gaps to prioritize!

