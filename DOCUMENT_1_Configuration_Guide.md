# URE Configuration Guide: Step-by-Step Setup
**Version:** 6.0 (Skill Bundle Architecture)  
**Audience:** Junior Developer  
**Last Updated:** April 2026

---

## Executive Summary

Think of URE like a **smart traffic controller**. You tell it:
1. **What to route** (e.g., Case with RecordType "Support")
2. **Who can handle it** (Agents with specific skills)
3. **How to pick the best agent** (matching + ranking)

All of this is defined via **metadata** (CMDT) so admins can configure routing *without touching code*.

---

## Part 1: The Data Model (What You Build)

### Layer 1: Custom Objects (Operational Data — Admin Creates)

#### Agent__c
**Purpose:** Represents one person on your team.

| Field | Type | Purpose |
|-------|------|---------|
| `User__c` | Lookup to User | Who is this agent? (required, unique index) |
| `Is_Active__c` | Checkbox | Is this agent available? |
| `Max_Capacity__c` | Number | Max items this agent can hold (e.g., 5 cases) |
| `Current_Load__c` | Number | How many items does agent currently have? |
| `Availability_Status__c` | Picklist | Online / Busy / Away / Offline |
| `Last_Assigned__c` | DateTime | When did this agent last get work? |

**Example Data (for this guide):**
```
Agent: Support Agent A
├─ User__c: John Smith (Id: 00590000...)
├─ Is_Active__c: ✓ (checked)
├─ Max_Capacity__c: 5
├─ Current_Load__c: 2
├─ Availability_Status__c: Online
└─ Last_Assigned__c: 2026-04-16 14:23:00
```

#### Skill_Bundle__c
**Purpose:** A reusable template of skills. Think of it like a "job role profile."

| Field | Type | Purpose |
|-------|------|---------|
| `Name` | Text | e.g., "Support Tier 1", "Billing Specialist" |
| `DeveloperName` | Text | e.g., `Support_Tier_1` (unique) |
| `Is_Active__c` | Checkbox | Is this template active? |

**Example:**
```
Skill Bundle: Support Tier 1
├─ DeveloperName: Support_Tier_1
├─ Is_Active__c: ✓
└─ Purpose: Basic support agents with General + English
```

#### Skill_Bundle_Entry__c (Master-Detail to Skill_Bundle__c)
**Purpose:** Individual skill assignments within a bundle.

| Field | Type | Purpose |
|-------|------|---------|
| `Skill_Bundle__c` | Master-Detail | Which bundle does this belong to? |
| `Agent_Skill__c` | Lookup to Agent_Skill__mdt | Which skill dimension? (e.g., "Language") |
| `Skill_Values__c` | Text (LongText) | Comma-separated values (e.g., "en_US,fr_CA") |

**Example:**
```
Entry 1: Support_Tier_1 → Language → "en_US,fr_CA"
Entry 2: Support_Tier_1 → ProductLine → "General,Billing"
```

#### Agent_Skill_Assignment__c (Junction: Agent to Skill_Bundle)
**Purpose:** Which bundles does a specific agent have?

| Field | Type | Purpose |
|-------|------|---------|
| `Agent__c` | Lookup to Agent__c | Which agent? |
| `Skill_Bundle__c` | Lookup to Skill_Bundle__c | Which bundle? |
| `Is_Active__c` | Checkbox | Is this assignment active? |

**Example:**
```
John Smith (agent) ← connected to → Support_Tier_1 (bundle)
└─ This means John has: Language (en_US, fr_CA) + ProductLine (General, Billing)
```

#### Routing_Log__c
**Purpose:** Insert-only audit trail. Every routing attempt is logged here.

| Field | Type | Purpose |
|-------|------|---------|
| `Record_Id__c` | Text | Which record was routed? (e.g., Case Id) |
| `Config_Developer_Name__c` | Text | Which routing config was used? |
| `Assigned_To__c` | Lookup to User | Who got assigned? |
| `Status__c` | Picklist | Success / No_Match / Locked / Error |
| `Error_Message__c` | Text | If failed, why? |
| `Candidate_Count__c` | Number | How many agents matched? |
| `Retry_Count__c` | Number | Locks? (0 = success on first try) |

---

### Layer 2: Custom Metadata Types (Configuration — Admin Creates)

#### Routing_Config__mdt
**The master config that says: "Route Cases with RecordType Support to any agent with Language skill."**

| Field | Type | Purpose | Example |
|-------|------|---------|---------|
| `DeveloperName` | Text | Unique identifier | `Case_Support_Routing` |
| `Active__c` | Checkbox | Is this enabled? | ✓ |
| `Object_API_Name__c` | Text | Which object to route? | `Case` |
| `Record_Type_Dev_Name__c` | Text | Which RecordType? (optional) | `Support` |
| `Owner_Field_API_Name__c` | Text | Which field stores the owner? | `OwnerId` |
| `Select_Fields__c` | Text (LongText) | Which fields to SELECT in query? | `Id, Subject, Priority, RecordTypeId` |
| `Candidate_Limit__c` | Number | Max candidates to evaluate | `200` |
| `Pre_Assignment_Owner_Type__c` | Picklist | Who pre-owns records? | `Unassigned` / `Null` / `Queue` |
| `Max_Retry_Attempts__c` | Number | Lock retry attempts | `3` |
| `Priority_Weight__c` | Number | Sort weight (higher = check first) | `100` |

**Example Record:**
```
Routing_Config__mdt Record: Case_Support_Routing
├─ DeveloperName: Case_Support_Routing
├─ Active__c: ✓
├─ Object_API_Name__c: Case
├─ Record_Type_Dev_Name__c: Support
├─ Owner_Field_API_Name__c: OwnerId
├─ Select_Fields__c: Id, Subject, Priority, RecordTypeId, Status, CreatedDate
├─ Candidate_Limit__c: 200
├─ Pre_Assignment_Owner_Type__c: Unassigned
├─ Max_Retry_Attempts__c: 3
└─ Priority_Weight__c: 100
```

**⚠️ IMPORTANT:** This must be deployed to Salesforce. It's part of the **managed package**.

---

#### Routing_Condition__mdt
**The matching rules: "Only assign if Priority = High"**

| Field | Type | Purpose | Example |
|-------|------|---------|---------|
| `Routing_Config__c` | Lookup | Which config is this part of? | Case_Support_Routing |
| `DeveloperName` | Text | Unique ID | `Condition_Priority` |
| `Is_Active__c` | Checkbox | Is this rule on? | ✓ |
| `Condition_Group__c` | Number | For OR logic (optional) | 1, 2, 3 (group A or group B) |
| `Field_API_Name__c` | Text | Which field on the record? | `Priority` |
| `Operator__c` | Picklist | Comparison operator | `EQUALS`, `NOT_EQUALS`, `INCLUDES`, `GREATER_THAN` |
| `Values__c` | Text (LongText) | What value to match? | `High;Critical` (multi-select) |
| `Is_Indexed__c` | Checkbox | Is this field indexed? (perf hint) | ✓ |
| `Sort_Order__c` | Number | Order of evaluation | 1, 2, 3... |

**Example Records:**
```
Condition 1: Case_Support_Routing → Priority = High
├─ Field_API_Name__c: Priority
├─ Operator__c: EQUALS
├─ Values__c: High
└─ Sort_Order__c: 1

Condition 2: Case_Support_Routing → Status != Closed
├─ Field_API_Name__c: Status
├─ Operator__c: NOT_EQUALS
├─ Values__c: Closed
└─ Sort_Order__c: 2
```

**Logic:** `(Priority = High) AND (Status != Closed)`

---

#### Routing_Skill_Mapping__mdt (v6 NEW)
**"Match agent skills to work record fields"**

This connects the skill system to routing conditions.

| Field | Type | Purpose | Example |
|-------|------|---------|---------|
| `Routing_Config__c` | Lookup | Which config? | Case_Support_Routing |
| `DeveloperName` | Text | Unique ID | `Skill_Match_Language` |
| `Agent_Skill__c` | Lookup to Agent_Skill__mdt | Which skill to match? | Language |
| `Work_Record_Field__c` | Text | Which field on the work record? | `Language__c` |
| `Is_Required__c` | Checkbox | Must agent have this skill? | ✓ |
| `Operator__c` | Picklist | How to match? | `INCLUDES` (agent's skill values include record's value) |

**Example:**
```
Routing_Skill_Mapping: Case_Support_Routing → Language Match
├─ Agent_Skill__c: Language (the skill dimension)
├─ Work_Record_Field__c: Language__c (field on Case)
├─ Operator__c: INCLUDES
├─ Is_Required__c: ✓ (agent MUST know this language)
```

**Translation:** "An agent can only get this case if their Language skill **includes** the case's Language__c value."

---

#### Agent_Skill__mdt
**Skill dimensions (the "skill catalog")**

| Field | Type | Purpose | Example |
|-------|------|---------|---------|
| `DeveloperName` | Text | Unique ID | `Language`, `ProductLine`, `SeniorityLevel` |
| `Label__c` | Text | Human-readable | "Language" |
| `Is_Active__c` | Checkbox | Is this enabled? | ✓ |

**Example Records:**
```
1. Language
   ├─ Label: "Language"
   ├─ Values allowed: en_US, fr_CA, es_MX, de_DE
   └─ Used by: Support_Tier_1 bundle (en_US, fr_CA)

2. ProductLine
   ├─ Label: "Product Line"
   ├─ Values allowed: General, Billing, Technical
   └─ Used by: Support_Tier_1 bundle (General, Billing)

3. SeniorityLevel
   ├─ Label: "Seniority"
   ├─ Values allowed: Tier1, Tier2, Tier3
   └─ NOT yet used by any bundle
```

**⚠️ IMPORTANT:** This is part of the **managed package** (ISV defines skill dimensions).

---

#### Routing_Priority__mdt
**How to rank candidates when multiple agents match.**

| Field | Type | Purpose | Example |
|-------|------|---------|---------|
| `Routing_Config__c` | Lookup | Which config? | Case_Support_Routing |
| `DeveloperName` | Text | Unique ID | `Priority_By_Load` |
| `Is_Active__c` | Checkbox | Is this on? | ✓ |
| `Field_API_Name__c` | Text | Which field to sort by? | `Current_Load__c` |
| `Sort_Direction__c` | Picklist | ASC or DESC? | `ASC` (lowest load first) |
| `Sort_Order__c` | Number | Which sort takes precedence? | 1 (primary), 2 (secondary) |

**Example Records:**
```
Priority 1: Sort by Current_Load (ASC) — agent with lowest load gets it first
Priority 2: Sort by Last_Assigned (ASC) — if tied, agent who waited longest
```

---

## Part 2: Step-by-Step Configuration Example

### Scenario
**You want to route Support Cases to agents who speak English.**

### Step 1: Create Agent Records (Salesforce Data)

In Salesforce, go to the **Agent** object and create:

```
Record 1:
- User: John Smith
- Is Active: ✓
- Max Capacity: 5
- Current Load: 0
- Availability: Online
- [SAVE]

Record 2:
- User: Maria Garcia
- Is Active: ✓
- Max Capacity: 5
- Current Load: 2
- Availability: Online
- [SAVE]
```

### Step 2: Create Skill Bundle (Salesforce Data)

Go to **Skill Bundle** and create:

```
Name: Support_Standard
Developer Name: Support_Standard
Is Active: ✓
[SAVE]
```

### Step 3: Add Skills to the Bundle (Skill_Bundle_Entry)

Create Skill_Bundle_Entry records linked to Support_Standard:

```
Entry 1:
- Skill Bundle: Support_Standard
- Agent Skill: Language (lookup)
- Skill Values: en_US
[SAVE]

Entry 2:
- Skill Bundle: Support_Standard
- Agent Skill: ProductLine
- Skill Values: General,Billing
[SAVE]
```

### Step 4: Assign Bundle to Agents (Agent_Skill_Assignment)

Create Agent_Skill_Assignment records:

```
Assignment 1:
- Agent: John Smith
- Skill Bundle: Support_Standard
- Is Active: ✓
[SAVE]

Assignment 2:
- Agent: Maria Garcia
- Skill Bundle: Support_Standard
- Is Active: ✓
[SAVE]
```

**Result:** Both agents now have Language=en_US and ProductLine=General,Billing skills.

---

### Step 5: Create Routing Config CMDT

**Go to Setup → Custom Metadata Types → Manage Records → Routing_Config**

Create a record:

```
Developer Name: Case_Support_Routing

Active: ✓

Object API Name: Case

Record Type Developer Name: Support

Owner Field API Name: OwnerId

Select Fields:
  Id, Subject, Priority, RecordTypeId, Status, 
  CreatedDate, Language__c

Candidate Limit: 200

Pre-Assignment Owner Type: Unassigned

Max Retry Attempts: 3

Priority Weight: 100

[SAVE RECORD]
```

---

### Step 6: Create Routing Conditions CMDT

**Go to Setup → Custom Metadata Types → Manage Records → Routing_Condition**

Create conditions to filter which cases get routed:

```
Condition 1:
- Routing Config: Case_Support_Routing
- Developer Name: Cond_Status
- Is Active: ✓
- Field API Name: Status
- Operator: NOT_EQUALS
- Values: Closed
- Sort Order: 1
[SAVE]

Condition 2:
- Routing Config: Case_Support_Routing
- Developer Name: Cond_Priority
- Is Active: ✓
- Field API Name: Priority
- Operator: EQUALS
- Values: High;Critical
- Sort Order: 2
[SAVE]
```

**Translation:** "Only route cases that are NOT Closed AND have Priority High or Critical."

---

### Step 7: Create Agent Skill Mappings CMDT

**Go to Setup → Custom Metadata Types → Manage Records → Routing_Skill_Mapping**

```
Record 1:
- Routing Config: Case_Support_Routing
- Developer Name: Match_Language
- Agent Skill: Language
- Work Record Field: Language__c
- Is Required: ✓
- Operator: INCLUDES
[SAVE]

Record 2:
- Routing Config: Case_Support_Routing
- Developer Name: Match_Product
- Agent Skill: ProductLine
- Work Record Field: Product_Line__c
- Is Required: ✗ (optional match)
- Operator: INCLUDES
[SAVE]
```

**Translation:**
- "Agent MUST have the language requested on the case"
- "Agent SHOULD ideally match product line (but not required)"

---

### Step 8: Create Routing Priorities CMDT

**Go to Setup → Custom Metadata Types → Manage Records → Routing_Priority**

```
Priority 1:
- Routing Config: Case_Support_Routing
- Developer Name: Sort_By_Load
- Is Active: ✓
- Field API Name: Current_Load__c
- Sort Direction: ASC (lowest load gets case first)
- Sort Order: 1
[SAVE]

Priority 2:
- Routing Config: Case_Support_Routing
- Developer Name: Sort_By_LastAssigned
- Is Active: ✓
- Field API Name: Last_Assigned__c
- Sort Direction: ASC (agent who waited longest)
- Sort Order: 2
[SAVE]
```

**Ranking:** "Prefer agent with lowest load. If tied, prefer agent who waited longest."

---

### Step 9: Test It Out!

#### Create a Case

```
Subject: "Cannot log in"
RecordType: Support
Status: New
Priority: High
Language__c: en_US
Product_Line__c: General
[SAVE]
```

#### Click "Next Best Action"

When John (online, load=0) clicks the button:
1. System finds Case (Status=New, Priority=High ✓)
2. Checks both agents speak en_US ✓
3. John has lowest load (0 vs 2) ✓
4. **Case assigned to John**
5. John's Current_Load__c incremented to 1
6. Routing_Log__c record created with status=Success

---

## Part 3: Dependency Map (What Goes Where)

### Managed Package (ISV Provides)
These ship with the package and live under `force-app/main/default/`:

```
Managed Package Contents:
├── Agent_Skill__mdt (ISV defines skill dimensions)
├── Routing_Config__mdt (structure)
├── Routing_Condition__mdt (structure)
├── Routing_Priority__mdt (structure)
├── Routing_Skill_Mapping__mdt (structure)
├── Agent__c (custom object)
├── Skill_Bundle__c (custom object)
├── Skill_Bundle_Entry__c (custom object)
├── Agent_Skill_Assignment__c (custom object)
├── Routing_Log__c (custom object)
└── Apex classes (RoutingEngine, etc.)
```

### Subscriber (End User Creates)
These go into the **org** where the package is installed:

```
Subscriber Setup:
├── Agent records (John Smith, Maria Garcia, etc.)
├── Skill_Bundle records (Support_Standard, etc.)
├── Skill_Bundle_Entry records (Language=en_US, etc.)
├── Agent_Skill_Assignment records (John → Support_Standard, etc.)
├── Routing_Config records (Case_Support_Routing, etc.) [CMDT — org-managed]
├── Routing_Condition records (Status != Closed, etc.) [CMDT — org-managed]
├── Routing_Priority records (Sort by Load, etc.) [CMDT — org-managed]
├── Routing_Skill_Mapping records (Match Language, etc.) [CMDT — org-managed]
└── [OPTIONAL] Skill_Bundle records (if adding org-specific roles)
```

**Key:** CMDT records for configs can be created by org admins via UI or tooling API.

---

## Part 4: Critical Setup Checklist

- [ ] **Agent__c records created** with User lookups (min. 1 agent)
- [ ] **Skill_Bundle__c record created** (e.g., Support_Standard)
- [ ] **Skill_Bundle_Entry records created** (linking skills to bundle)
- [ ] **Agent_Skill_Assignment records created** (assigning bundles to agents)
- [ ] **Agent_Skill__mdt records exist** (ISV provides Language, ProductLine, etc.)
- [ ] **Routing_Config__mdt record created** (Case_Support_Routing)
- [ ] **Routing_Condition__mdt records created** (Status != Closed, Priority = High)
- [ ] **Routing_Skill_Mapping__mdt records created** (Language match, Product match)
- [ ] **Routing_Priority__mdt records created** (Sort by Load, then Last_Assigned)
- [ ] **Test Case created** with matching criteria (Status=New, Priority=High, Language__c=en_US)
- [ ] **Agent clicks "Next Best Action"** → Case gets assigned to lowest-load agent

---

## Appendix: Field Validation Rules

| CMDT | Field | Validation |
|------|-------|-----------|
| Routing_Config | Object_API_Name | Must be valid SObject API name (e.g., Case, Task) |
| Routing_Config | Owner_Field_API_Name | Must be valid field on that SObject (e.g., OwnerId) |
| Routing_Condition | Field_API_Name | Must be valid field on the routed SObject |
| Routing_Condition | Operator | EQUALS, NOT_EQUALS, INCLUDES, EXCLUDES, LESS_THAN, GREATER_THAN, etc. |
| Routing_Skill_Mapping | Agent_Skill__c | Must exist in Agent_Skill__mdt |
| Routing_Skill_Mapping | Work_Record_Field | Must be a field on Routing_Config.Object_API_Name |

---

## Appendix: Data Example (Full Setup)

### Salesforce Data (Objects)

```json
{
  "Agent__c": [
    {
      "Name": "John Smith",
      "User__c": "0051i000000IZ3AAM",
      "Is_Active__c": true,
      "Max_Capacity__c": 5,
      "Current_Load__c": 0,
      "Availability_Status__c": "Online"
    },
    {
      "Name": "Maria Garcia",
      "User__c": "0051i000000IZ3BBN",
      "Is_Active__c": true,
      "Max_Capacity__c": 5,
      "Current_Load__c": 2,
      "Availability_Status__c": "Online"
    }
  ],
  "Skill_Bundle__c": [
    {
      "Name": "Support_Standard",
      "DeveloperName": "Support_Standard",
      "Is_Active__c": true
    }
  ],
  "Skill_Bundle_Entry__c": [
    {
      "Skill_Bundle__c": "m01xx000...", // Support_Standard ID
      "Agent_Skill__c": "a00xx000...", // Language ID
      "Skill_Values__c": "en_US"
    },
    {
      "Skill_Bundle__c": "m01xx000...",
      "Agent_Skill__c": "a00xx000...", // ProductLine ID
      "Skill_Values__c": "General,Billing"
    }
  ],
  "Agent_Skill_Assignment__c": [
    {
      "Agent__c": "a00xx000...", // John
      "Skill_Bundle__c": "m01xx000...", // Support_Standard
      "Is_Active__c": true
    },
    {
      "Agent__c": "a00xx000...", // Maria
      "Skill_Bundle__c": "m01xx000...",
      "Is_Active__c": true
    }
  ]
}
```

### CMDT Data (Managed Package / Org-Managed)

```xml
<!-- Routing_Config__mdt -->
<record>
  <fullName>Case_Support_Routing</fullName>
  <fields>
    <name>Active__c</name>
    <value>true</value>
  </fields>
  <fields>
    <name>Candidate_Limit__c</name>
    <value>200</value>
  </fields>
  <fields>
    <name>Object_API_Name__c</name>
    <value>Case</value>
  </fields>
  <fields>
    <name>Owner_Field_API_Name__c</name>
    <value>OwnerId</value>
  </fields>
  <fields>
    <name>Record_Type_Dev_Name__c</name>
    <value>Support</value>
  </fields>
  <fields>
    <name>Select_Fields__c</name>
    <value>Id, Subject, Priority, RecordTypeId, Status, Language__c</value>
  </fields>
</record>

<!-- Routing_Condition__mdt -->
<record>
  <fullName>Cond_Status</fullName>
  <fields>
    <name>Routing_Config__c</name>
    <value>Case_Support_Routing</value>
  </fields>
  <fields>
    <name>Field_API_Name__c</name>
    <value>Status</value>
  </fields>
  <fields>
    <name>Operator__c</name>
    <value>NOT_EQUALS</value>
  </fields>
  <fields>
    <name>Values__c</name>
    <value>Closed</value>
  </fields>
</record>

<!-- Routing_Skill_Mapping__mdt -->
<record>
  <fullName>Match_Language</fullName>
  <fields>
    <name>Routing_Config__c</name>
    <value>Case_Support_Routing</value>
  </fields>
  <fields>
    <name>Agent_Skill__c</name>
    <value>Language</value>
  </fields>
  <fields>
    <name>Work_Record_Field__c</name>
    <value>Language__c</value>
  </fields>
  <fields>
    <name>Is_Required__c</name>
    <value>true</value>
  </fields>
</record>
```

---

**NEXT:** Read Document 2 to understand how the routing engine executes when "Next Best Action" is clicked.
