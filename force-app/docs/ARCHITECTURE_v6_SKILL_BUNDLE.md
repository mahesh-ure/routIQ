# routIQ v6 — Skill Bundle Data Model Architecture

> **Version:** 6.0
> **Date:** 2026-03-22
> **Author:** CTA Architecture Review
> **Status:** Approved for implementation
> **Branch:** feature/skill-bundle-refactor

---

## 1. Executive Summary

Version 6 introduces the **Skill Bundle pattern** to replace the flat Agent-to-Skill join
(`Agent_Capability_Value__c`) that caused an N x M record explosion. Agents are now assigned
**reusable skill bundles** (named templates) instead of individual skill records. This reduces
configuration records by **89-98%** at scale while simplifying admin setup from "create 50
individual records per agent" to "assign 1-2 bundles per agent."

---

## 2. Problem Statement

### v5 Flat Model (Before)

```
Agent__c ──(1:N)──> Agent_Capability_Value__c
                    (one record per agent per skill dimension)
```

| Scale | Agent_Capability_Value__c Records | Total Records |
|---|---|---|
| 50 agents x 50 skills | 2,500 | 2,662 |
| 500 agents x 50 skills | 25,000 | 25,162 |
| 5,000 agents x 50 skills | 250,000 | 250,162 |

**Issues:**
- Governor limit risk: 250K SOQL rows for capability query
- Platform Cache bloat: caching 250K SObject records
- Admin setup fatigue: manual creation of N x M records
- Data Loader complexity: 250K rows with 3 columns each
- Onboarding friction: new agent requires 50 individual records

### Real-World Observation

Agents cluster into **roles**. In a 50-agent org:
- 18 agents share identical Case skills
- 2 agents share those Case skills + extras
- 25 agents share identical Opportunity skills
- 5 agents share those Opp skills + extras

The flat model ignores this clustering entirely.

---

## 3. Solution: Skill Bundle Pattern

### v6 Bundle Model (After)

```
Agent__c ◄──(M:N)──> Skill_Bundle__c
  (via Agent_Skill_Assignment__c)       │
                                        │ 1:N (Master-Detail)
                                        ▼
                                Skill_Bundle_Entry__c
                                (bundle -> skill -> values)
                                        │
                                        │ Text ref (DeveloperName)
                                        ▼
                                Agent_Skill__mdt
                                (skill dimension definition)
```

| Scale | Bundle Records | Total Records | Reduction |
|---|---|---|---|
| 50 agents x 50 skills | 126 | 288 | **89%** |
| 500 agents x 50 skills | 600 | 762 | **97%** |
| 5,000 agents x 50 skills | 5,664 | 5,826 | **97.7%** |

---

## 4. Complete Data Model

### 4.1 Relationship Diagram

```
                    CMDT LAYER (zero SOQL — platform-cached)
 ┌────────────────────────────────────────────────────────────────┐
 │                                                                │
 │  Routing_Config__mdt                                           │
 │    │                                                           │
 │    ├──(1:N)──> Routing_Condition__mdt   (WHERE filters)        │
 │    ├──(1:N)──> Routing_Priority__mdt    (ORDER BY specs)       │
 │    │                                                           │
 │    └──(1:N)──> Routing_Skill_Mapping__mdt (config->skill->field│
 │                    │                       mapping)            │
 │                    │ MetadataRelationship                      │
 │                    ▼                                           │
 │               Agent_Skill__mdt  (Province, Language, etc.)     │
 │                                                                │
 └────────────────────────────────────────────────────────────────┘
                          │
                Text ref (DeveloperName)
                          │
              CUSTOM OBJECT LAYER (operational, admin-managed)
 ┌────────────────────────────────────────────────────────────────┐
 │                                                                │
 │  Agent__c                                                      │
 │    │                                                           │
 │    └──(M:N)──> Skill_Bundle__c                                 │
 │      (via Agent_Skill_Assignment__c)                           │
 │                    │                                           │
 │                    └──(1:N Master-Detail)──> Skill_Bundle_Entry__c
 │                        (bundle -> Agent_Skill devname -> values)│
 │                                                                │
 │  Routing_Log__c  (audit trail, unchanged)                      │
 │  Log__c / Log_Entry__c  (framework logging, unchanged)         │
 │                                                                │
 └────────────────────────────────────────────────────────────────┘
```

---

### 4.2 CMDT Objects (Structural — Rarely Change)

#### 4.2.1 Routing_Config__mdt (UNCHANGED)

Root configuration — one record per routing scenario.

| Field | Type | Required | Manageability | Description |
|---|---|---|---|---|
| DeveloperName | String (key) | Yes | — | Unique identifier |
| Active__c | Checkbox | — | Subscriber | Routing enabled |
| Object_API_Name__c | Text(255) | Yes | Subscriber | SObject to route (e.g. "Case") |
| Owner_Field_API_Name__c | Text(255) | Yes | Subscriber | Field to assign (e.g. "OwnerId") |
| Priority_Weight__c | Number | — | Subscriber | Lower = higher priority |
| Candidate_Limit__c | Number | — | Subscriber | Max records per query (default 50) |
| Allow_Multiple__c | Checkbox | — | Subscriber | Agent can receive multiple records |
| Closed_Status_Values__c | LongTextArea(1000) | — | Subscriber | Comma-delimited closed statuses |
| Pre_Assignment_Owner_Type__c | Text(50) | — | Subscriber | FOR UPDATE re-validation |
| Record_Type_Dev_Name__c | Text(255) | — | Subscriber | RecordType filter |
| Select_Fields__c | LongTextArea(1000) | — | Subscriber | Additional SELECT fields |
| Max_Retry_Attempts__c | Number | — | Subscriber | Lock retry count (default 1) |

---

#### 4.2.2 Routing_Condition__mdt (UNCHANGED)

N conditions per config — WHERE clause filters.

| Field | Type | Required | Description |
|---|---|---|---|
| DeveloperName | String (key) | Yes | Unique identifier |
| Routing_Config__c | MetadataRelationship | Yes | Parent config |
| Field_API_Name__c | Text(255) | Yes | Work record field |
| Operator__c | Picklist | Yes | IN, NOT IN, =, !=, <, >, INCLUDES, EXCLUDES, etc. |
| Value_Source__c | Picklist | Yes | STATIC or USER_ATTRIBUTE |
| Values__c | LongTextArea(4000) | Cond. | Static values (comma-delimited) |
| User_Attribute_Field__c | Text(255) | Cond. | User field for runtime values |
| Value_Type__c | Picklist | Yes | String, Number, Boolean, Date, DateTime |
| Condition_Group__c | Number | — | null/0=root AND, 1,2,3...=OR groups |
| Is_Active__c | Checkbox | — | Default: true |
| Is_Indexed__c | Checkbox | — | Informational |
| Sort_Order__c | Number | — | Evaluation sequence |

**Grouping Model:**
```
WHERE (root conditions AND-joined)
  AND (
    (group 1 conditions AND-joined)
    OR (group 2 conditions AND-joined)
    OR (group N conditions AND-joined)
  )
```

---

#### 4.2.3 Routing_Priority__mdt (UNCHANGED)

ORDER BY specification per config.

| Field | Type | Required | Description |
|---|---|---|---|
| DeveloperName | String (key) | Yes | Unique identifier |
| Routing_Config__c | MetadataRelationship | Yes | Parent config |
| Sort_Field_API_Name__c | Text(255) | Yes | Field to sort by |
| Sort_Direction__c | Picklist | Yes | ASC or DESC |
| Null_Handling__c | Picklist | Yes | NULLS FIRST or NULLS LAST |
| Sort_Order__c | Number | Yes | 1=primary, 2=secondary, etc. |

---

#### 4.2.4 Agent_Skill__mdt (RENAMED from Agent_Capability__mdt)

Defines skill dimensions — the categories of agent expertise.

| Field | Type | Required | Manageability | Description |
|---|---|---|---|---|
| DeveloperName | String (key) | Yes | — | e.g. `Province`, `Language`, `Product_Line` |
| Label__c | Text(255) | Yes | Subscriber | Human-readable name for UI/errors |
| Is_Active__c | Checkbox | — | Subscriber | Default: true. Inactive excluded from matching |

**Example Records:**
```
Province          Label: "Province"        Is_Active: true
Language          Label: "Language"        Is_Active: true
Product_Line      Label: "Product Line"    Is_Active: true
```

---

#### 4.2.5 Routing_Skill_Mapping__mdt (RENAMED from Agent_Match_Condition__mdt)

Junction CMDT — maps which skill dimensions apply to which routing configs, and which
work record field to compare against.

| Field | Type | Required | Manageability | Description |
|---|---|---|---|---|
| DeveloperName | String (key) | Yes | — | e.g. `Case_Province_Map` |
| Routing_Config__c | MetadataRelationship(Routing_Config__mdt) | Yes | Subscriber | Parent routing config |
| Agent_Skill__c | MetadataRelationship(Agent_Skill__mdt) | Yes | Subscriber | Which skill dimension |
| Field_API_Name__c | Text(255) | Yes | Subscriber | Work record field (e.g. "Province__c") |
| Is_Mandatory__c | Checkbox | — | Subscriber | Default: true. Mandatory = hard filter |
| Sort_Order__c | Number | — | Subscriber | Evaluation sequence |

**Why separate from Agent_Skill__mdt?** Same skill dimension can map to different field names
on different objects:
- Province skill -> `Province__c` on Case
- Province skill -> `Service_Region__c` on WorkOrder

**Example Records:**
```
Case_Province_Map:
  Routing_Config: Case_Routing
  Agent_Skill: Province
  Field_API_Name: Province__c
  Is_Mandatory: true
  Sort_Order: 1

Case_Language_Map:
  Routing_Config: Case_Routing
  Agent_Skill: Language
  Field_API_Name: Required_Language__c
  Is_Mandatory: false
  Sort_Order: 2
```

---

### 4.3 Custom Objects (Operational — Admin-Managed)

#### 4.3.1 Agent__c (UNCHANGED)

One record per routing agent.

| Field | Type | Required | Description |
|---|---|---|---|
| Name | AutoNumber `AGT-{0000000}` | Auto | Agent number |
| User__c | Lookup(User) | — | Link to Salesforce User (SetNull on delete) |
| Is_Active__c | Checkbox | — | Default: true. Inactive agents excluded |
| Max_Capacity__c | Number(18,0) | Yes | Max concurrent open items (default 5) |
| Current_Load__c | Number(18,0) | — | Current open items (default 0) |
| Last_Assigned__c | DateTime | — | Timestamp of last assignment |

---

#### 4.3.2 Skill_Bundle__c (NEW)

A named, reusable group of skill values. Represents a role profile (e.g. "Case Tier-1",
"Opp Enterprise", "Bilingual").

| Field | Type | Required | Description |
|---|---|---|---|
| Name | AutoNumber `SKB-{0000000}` | Auto | Bundle number |
| Bundle_Name__c | Text(255) | Yes | Admin-facing label. Unique. |
| Description__c | LongTextArea(2000) | — | Purpose documentation |
| Is_Active__c | Checkbox | — | Default: true. Inactive excluded from matching |
| Object_Context__c | Text(255) | — | Informational grouping: "Case", "Opportunity", etc. |

**Design Decisions:**
- **Custom Object, not CMDT**: Bundles are operational data admins create/modify frequently.
  CMDT would require metadata deployment. Custom Object allows point-and-click + Data Loader.
- **AutoNumber Name**: Prevents naming conflicts. Bundle_Name__c is the user-facing identifier.
- **Object_Context__c is informational only**: A bundle can be assigned to agents routing any
  object. This field is for admin organization and Setup Wizard filtering.

**Example Records:**
```
SKB-0000001  Bundle_Name: "Case Tier 1"       Object_Context: "Case"
SKB-0000002  Bundle_Name: "Case Tier 2 Extra"  Object_Context: "Case"
SKB-0000003  Bundle_Name: "Opp Standard"       Object_Context: "Opportunity"
SKB-0000004  Bundle_Name: "Opp Enterprise"     Object_Context: "Opportunity"
SKB-0000005  Bundle_Name: "Bilingual"          Object_Context: null (cross-object)
```

---

#### 4.3.3 Skill_Bundle_Entry__c (NEW)

One entry per skill dimension per bundle. Defines what values the bundle provides for
each skill.

| Field | Type | Required | Description |
|---|---|---|---|
| Name | AutoNumber `SBE-{0000000}` | Auto | Entry number |
| Skill_Bundle__c | Master-Detail(Skill_Bundle__c) | Yes | Parent bundle (cascade delete) |
| Agent_Skill__c | Text(255) | Yes | DeveloperName of Agent_Skill__mdt |
| Values__c | LongTextArea(4000) | Yes | Comma/semicolon delimited values |

**Design Decisions:**
- **Master-Detail to Skill_Bundle__c**: Entries cascade delete when bundle is deleted.
  Rollup summaries possible (entry count, etc.).
- **Agent_Skill__c is Text, not Lookup**: References CMDT DeveloperName. Same pattern as
  the original Agent_Capability_Value__c.Agent_Capability__c. Allows cross-object-type
  resolution at runtime without FK constraints between Custom Object and CMDT.
- **Values__c supports comma AND semicolon delimiters**: Consistent with existing parsing
  logic in AgentCapabilitySelector.parseDelimitedValues().

**Example Records:**
```
Bundle: "Case Tier 1"
  SBE-001  Agent_Skill: Province     Values: "Ontario,Quebec,BC"
  SBE-002  Agent_Skill: Language     Values: "English"
  SBE-003  Agent_Skill: Product_Line Values: "Residential,Commercial"

Bundle: "Bilingual"
  SBE-010  Agent_Skill: Language     Values: "French"
```

---

#### 4.3.4 Agent_Skill_Assignment__c (NEW — replaces Agent_Capability_Value__c)

M:N junction between Agent and Skill Bundle. An agent can have multiple bundles.

| Field | Type | Required | Description |
|---|---|---|---|
| Name | AutoNumber `ASA-{0000000}` | Auto | Assignment number |
| Agent__c | Lookup(Agent__c) | Yes | Parent agent (Restrict delete) |
| Skill_Bundle__c | Lookup(Skill_Bundle__c) | Yes | Assigned bundle (Restrict delete) |
| Is_Active__c | Checkbox | — | Default: true. Allows temp deactivation |

**Design Decisions:**
- **Dual Lookup (not Master-Detail)**: Both sides are parents. Restrict on delete prevents
  orphan assignments if either agent or bundle is deleted.
- **Is_Active__c for soft deactivation**: Admin can temporarily remove a bundle from an agent
  without deleting the assignment record. Useful during training/transitions.
- **Uniqueness**: Agent__c + Skill_Bundle__c should be unique (enforced via duplicate rule or
  validation rule — no native compound unique index in Salesforce).

**Example Records:**
```
ASA-001  Agent: AGT-001 (Sarah)   Bundle: "Case Tier 1"     Is_Active: true
ASA-002  Agent: AGT-001 (Sarah)   Bundle: "Bilingual"        Is_Active: true
ASA-003  Agent: AGT-002 (James)   Bundle: "Case Tier 1"     Is_Active: true
ASA-004  Agent: AGT-003 (Priya)   Bundle: "Opp Standard"    Is_Active: true
ASA-005  Agent: AGT-003 (Priya)   Bundle: "Opp Enterprise"  Is_Active: true
```

---

#### 4.3.5 Routing_Log__c (UNCHANGED)

Insert-only audit trail for routing decisions.

---

### 4.4 Retired Objects

| Object | Replaced By | Migration |
|---|---|---|
| Agent_Capability__mdt | Agent_Skill__mdt | Rename in source (same structure) |
| Agent_Match_Condition__mdt | Routing_Skill_Mapping__mdt | Rename in source (same structure, updated MD relationship) |
| Agent_Capability_Value__c | Skill Bundle system | Delete from source. No customer data exists (pre-GA). |

---

## 5. Runtime Data Flow

### 5.1 Skill Resolution Pipeline

```
AgentCapabilitySelector.getCapabilityMap()
    │
    ├── SOQL 1: Agent__c WHERE Is_Active__c = true
    │           → Map<UserId, Agent__c>   (transaction-cached)
    │
    ├── SOQL 2: Agent_Skill_Assignment__c WHERE Agent__c IN :agentIds
    │           AND Is_Active__c = true
    │           → Map<AgentId, Set<BundleId>>   (transaction-cached)
    │
    ├── SOQL 3: Skill_Bundle_Entry__c WHERE Skill_Bundle__c IN :allBundleIds
    │           → Map<BundleId, List<Entry>>   (transaction + platform cached)
    │
    └── MERGE: For each agent → for each bundle → UNION all entry values
              → Final: Map<AgentId, Map<SkillDevName, Set<Values>>>
```

### 5.2 SOQL Cost Comparison

| Metric | v5 (Flat) | v6 (Bundle) |
|---|---|---|
| SOQL queries | 2 | 3 |
| Max rows (5K agents, 50 skills) | 255,000 | 5,700 |
| Platform Cache items | 250,000 | ~300 (bundle entries only) |
| Cache effectiveness | Poor (too large) | Excellent (small, shared) |

**Net:** +1 SOQL, -99.9% rows. The bundle entries are shared across agents, so caching
is dramatically more effective.

### 5.3 Merge Semantics (UNION — Always Additive)

When an agent has multiple bundles defining the same skill dimension:

```
Agent "Sarah" has:
  Bundle "Case Tier 1"   → Province = {Ontario, Quebec}
  Bundle "Bilingual"     → Language = {French}
  Bundle "BC Extension"  → Province = {BC}

Merged result for Sarah:
  Province = {Ontario, Quebec, BC}    ← UNION
  Language = {French}                 ← Single source
```

**Rule: Always UNION. Never replace, never subtract.**

This is the only conflict-free semantic for composable skill profiles. If an admin needs to
restrict an agent, they assign a more limited bundle or remove the broader one.

---

## 6. Class Impact Analysis

| Class | Change | Scope | Reason |
|---|---|---|---|
| **AgentCapabilitySelector** | REWRITE internals | Medium | New 3-SOQL pipeline + merge logic. Output signature unchanged. |
| **RoutingConfigSelector** | Rename references | Small | Agent_Capability__mdt -> Agent_Skill__mdt, Agent_Match_Condition__mdt -> Routing_Skill_Mapping__mdt |
| **ConfigLoader** | Rename references | Small | Same CMDT grouping logic, updated type names |
| **ConfigBundle** | Rename type refs | Small | Agent_Match_Condition__mdt -> Routing_Skill_Mapping__mdt |
| **AgentMatcher** | ZERO changes | None | Consumes same Map<Id, Map<String, Set<String>>> |
| **AssignmentResolver** | ZERO changes | None | Doesn't touch capabilities |
| **RoutingEngine** | ZERO changes | None | Orchestrates, doesn't know data source |
| **RuleEvaluator** | ZERO changes | None | Config applicability only |
| **DynamicQueryBuilder** | ZERO changes | None | Builds SOQL from conditions only |
| **ConditionBinder** | ZERO changes | None | Binds condition values only |
| **CandidateSelector** | ZERO changes | None | Executes built SOQL |
| **RetryLockHandler** | ZERO changes | None | Locking only |
| **AuditLogger** | ZERO changes | None | Logging only |
| **CapabilityMismatchException** | Rename to SkillMismatchException | Small | Cosmetic alignment |
| **Tests** | Update mock data | Medium | Use bundle pattern in test setup |

**Key insight:** The layered architecture pays dividends. Because AgentCapabilitySelector
encapsulates ALL data access behind `getCapabilityMap()`, the bundle refactor is invisible
to every class above it in the stack.

---

## 7. Configuration Example

### Scenario: 50 Agents routing Cases + Opportunities

**Step 1: Define Skill Dimensions (Agent_Skill__mdt — CMDT, deployed once)**
```
Province        Label: "Province"
Language        Label: "Language"
Product_Line    Label: "Product Line"
... (20 Case skills + 30 Opp skills = 50 total)
```

**Step 2: Map Skills to Routing Configs (Routing_Skill_Mapping__mdt — CMDT)**
```
Case_Province_Map    → Case_Routing config → Province skill → Province__c field
Case_Language_Map    → Case_Routing config → Language skill → Required_Language__c field
Opp_Product_Map      → Opp_Routing config  → Product_Line  → Product_Family__c field
... (50 mappings total)
```

**Step 3: Create Skill Bundles (Skill_Bundle__c — Custom Object, admin UI)**
```
Case Tier 1          → 20 entries (standard Case skills)
Case Tier 2 Extra    → 5 entries (additional Case skills)
Opp Standard         → 30 entries (standard Opp skills)
Opp Enterprise       → 10 entries (additional Opp skills)
```

**Step 4: Assign Bundles to Agents (Agent_Skill_Assignment__c — Custom Object)**
```
18 agents × 1 bundle (Case Tier 1)              = 18 assignments
2 agents × 2 bundles (Case Tier 1 + Extra)       = 4 assignments
25 agents × 1 bundle (Opp Standard)              = 25 assignments
5 agents × 2 bundles (Opp Standard + Enterprise) = 10 assignments
                                            Total = 57 assignments
```

**Total records created: 288** (vs 2,662 in v5 flat model)

---

## 8. Object Metadata Specifications

### 8.1 Skill_Bundle__c

```xml
Label:        Skill Bundle
Plural:       Skill Bundles
Name Field:   AutoNumber SKB-{0000000}
Sharing:      ReadWrite
Deployment:   Deployed
Description:  A reusable group of skill values that can be assigned to agents.
              Each bundle represents a role profile (e.g. "Case Tier 1",
              "Opp Enterprise", "Bilingual"). Agents can have multiple bundles
              assigned — their skills are the UNION of all bundle entries.
```

### 8.2 Skill_Bundle_Entry__c

```xml
Label:        Skill Bundle Entry
Plural:       Skill Bundle Entries
Name Field:   AutoNumber SBE-{0000000}
Sharing:      ControlledByParent (Master-Detail)
Deployment:   Deployed
Description:  One entry per skill dimension per bundle. Defines what values
              the bundle provides for a given skill (e.g. Province = "ON,QC,BC").
```

### 8.3 Agent_Skill_Assignment__c

```xml
Label:        Agent Skill Assignment
Plural:       Agent Skill Assignments
Name Field:   AutoNumber ASA-{0000000}
Sharing:      ReadWrite
Deployment:   Deployed
Description:  M:N junction linking agents to skill bundles. An agent can have
              multiple bundles. At runtime, all bundle entries are merged via
              UNION to determine the agent's complete skill profile.
```

---

## 9. Platform Cache Strategy (v6)

### What to Cache

| Data | Cache Tier | TTL | Key | Size (5K agents) |
|---|---|---|---|---|
| Agent__c records | Transaction (static) | Per-txn | — | 5,000 records |
| Agent_Skill_Assignment__c | Transaction (static) | Per-txn | — | ~5,500 records |
| Skill_Bundle_Entry__c | Platform Cache + Transaction | 300s | `agent_bundle_entries` | ~300 records |

### Why Bundle Entries in Platform Cache (not Assignments)

- Bundle entries are **shared across agents** — 20 agents on "Case Tier 1" share the same 20 entries
- Assignments are **per-agent** — more volatile, less cache benefit
- Caching ~300 bundle entries vs 250K capability values = 99.9% size reduction

---

## 10. Security Considerations

| Concern | Mitigation |
|---|---|
| CRUD/FLS on new objects | All queries use AccessLevel.USER_MODE |
| Bundle tampering | Permission Sets control access to Skill_Bundle__c |
| Injection via Values__c | All values flow through bind variables, never string-interpolated |
| Orphan assignments | Restrict delete on Agent__c and Skill_Bundle__c lookups |
| Duplicate assignments | Validation rule: Agent + Bundle must be unique |

---

## 11. Upgrade Path

Since routIQ is pre-GA, this is a clean refactor:

1. Create new objects (Skill_Bundle__c, Skill_Bundle_Entry__c, Agent_Skill_Assignment__c)
2. Rename CMDTs (Agent_Capability__mdt -> Agent_Skill__mdt, Agent_Match_Condition__mdt -> Routing_Skill_Mapping__mdt)
3. Delete retired object (Agent_Capability_Value__c)
4. Update Apex classes
5. Update customMetadata records
6. Update tests

No data migration required — no customer orgs have data yet.
