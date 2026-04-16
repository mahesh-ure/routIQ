# CLAUDE.md
Salesforce AppExchange ISV Architecture Guidelines

This repository builds a **Salesforce AppExchange application** intended for distribution as a **managed package**.

AI agents operating in this project must act as **Salesforce Certified Technical Architects (CTA)** and follow **ISV-grade architectural standards**.

The system must be:

- Multi-tenant safe
- Metadata driven
- Upgrade safe
- Security review compliant
- Highly scalable

Primary technologies used:

- Apex
- Lightning Web Components (LWC)
- Aura (legacy support)
- Flow
- Custom Objects
- Custom Metadata Types
- Platform Events
- Permission Sets

---

# 1. Core Architecture Philosophy

The system must follow these design principles.

### 1. Metadata Driven Architecture

All business logic must be configurable using:

- Custom Metadata Types
- Custom Settings
- Platform configuration

Hardcoding behavior is prohibited.

Examples of metadata driven behavior:

• routing logic  
• feature flags  
• query templates  
• workflow rules  
• UI behavior  
• permissions

Example metadata:

Routing_Rule__mdt
Feature_Flag__mdt
Query_Template__mdt

### 1a. No Hardcoded Values in Apex — Custom Settings Required

**All tunable runtime values in Apex MUST be stored in Custom Settings (Hierarchy type), NOT as constants or magic numbers.**

This applies to:

- Numeric thresholds (days, limits, counts, timeouts)
- Feature toggles (booleans)
- Default string values (status names, field API names)
- Query parameters (LIMIT values, lookback windows)

Rules:

1. Create a Hierarchy Custom Setting per feature area (e.g. `Analytics_Settings__c`)
2. Read via `getInstance()` — zero SOQL, platform-cached, hierarchy-aware
3. Always provide a compile-time FALLBACK constant for when the setting record does not exist (fresh install safety net)
4. FALLBACK constants must be clearly named (e.g. `FALLBACK_DAYS`, not `DEFAULT_DAYS`)
5. The Custom Setting is the source of truth — the fallback is a safety net, not a default
6. Add inline help text and description on every Custom Setting field
7. Include the Custom Setting fields in the appropriate Permission Set

Benefits:

- Subscriber admins can tune values without code changes
- Per-user or per-profile overrides via Hierarchy resolution
- Package upgrades do not reset subscriber values
- Zero governor cost at runtime

Current Custom Settings in this package:

| Custom Setting | Feature | Fields |
|---|---|---|
| `Analytics_Settings__c` | P2 Analytics Dashboard | `Default_Lookback_Days__c`, `Max_Query_Rows__c` |

When adding hardcoded values to any new feature, check this table first. If a suitable Custom Setting exists, add a field to it. If not, create a new one.

---

### 2. Layered Architecture

All code must follow a layered architecture.

Rules:

- UI must never contain business logic
- Triggers must contain no logic
- Queries must live only in selectors
- Services orchestrate business workflows

---

# 3. Enterprise Trigger Framework

All triggers must use a **single reusable trigger framework**.

Rules:

- One trigger per object
- No logic inside triggers
- Triggers delegate to handlers
- Handlers call domain/services


---

# 4. Selector Framework (Data Access Layer)

Selectors centralize SOQL queries.

Benefits:

- reusable
- testable
- query optimization
- security enforcement


Rules:

- Selectors must not contain business logic
- All queries must live in selectors
- Queries must support bulk usage

---

# 5. Service Layer

Service classes orchestrate business workflows.


Rules:

- Services must be stateless
- Bulk safe
- Transaction aware
- Secure

---

# 6. Metadata Driven Query Engine

The application supports dynamic queries defined in **Custom Metadata**.


The engine composes SOQL dynamically using metadata configuration.

Security requirements:

- Validate object access
- Validate field access
- Prevent injection

---

# 7. Dynamic Routing Engine Architecture

The platform includes a **metadata driven routing engine** used for:

- case routing
- lead assignment
- task assignment
- work distribution
- Custom Object routing

Routing metadata:

Routing must support:

- dynamic filters
- user attributes
- queue assignment
- round robin strategies

---

# 8. Lightning Web Components Architecture

All new UI must use **LWC**.

Structure:

Guidelines:

UI must:

- remain presentation focused
- avoid business logic
- use Apex services

Preferred data access order:

1 Lightning Data Service  
2 UI API  
3 Apex

---

# 9. Aura Components

Aura exists only for:

- legacy compatibility
- interface implementations
- record page overrides

New UI must not be Aura.

---

# 10. Flow Integration Pattern

Flows orchestrate admin automation.

Flows must delegate heavy logic to Apex.

Pattern:

Invocable methods must remain thin.

---

# 11. Multi-Tenant Safe Design

Because this is an AppExchange product, all code must be multi-tenant safe.

Rules:

Never reference:

- Profile names
- Role names
- Org specific IDs
- Custom fields outside package

Use:

- Permission Sets
- Custom Metadata
- Feature Flags

---

# 12. Namespace Safe Development

All metadata must support namespaced environments.

Bad:
MyObject__c

Good:
Schema.getGlobalDescribe()

Use dynamic resolution whenever possible.

---

# 13. Feature Flag Architecture

Feature flags enable safe rollout of features.

Metadata:

---

# 15. Asynchronous Processing

Use async processing when needed.

Tools:

Queueable Apex  
Batch Apex  
Platform Events  
Scheduled Jobs

Guideline:

Heavy processing must not occur in triggers.

---

# 16. AppExchange Security Review Compliance

All code must pass Salesforce Security Review.

Required protections:

### SOQL Injection Protection

Never concatenate queries.

Use bind variables.

---

### CRUD / FLS Enforcement

All Apex must enforce object and field permissions.

Use:

Security.stripInaccessible()

---

### Cross Site Scripting

LWC must sanitize:

- user input
- HTML rendering

Never render raw HTML.

---

### Secure Callouts

External integrations must:

- use Named Credentials
- avoid storing secrets in code

---

# 17. Test Strategy

Minimum:

90% coverage across package.

Tests must include:

- bulk tests
- negative tests
- permission tests
- async tests

Test structure:

---

# 18. Package Upgrade Safety

Never:

- rename fields
- delete metadata
- change API names

Instead:

- deprecate
- version metadata
- introduce new fields

---

# 19. Repository Structure

Standard Salesforce DX project structure:

```
routIQ/                              # Project root
├── .gitignore                       # Excludes .sf/, .sfdx/, node_modules/
├── .forceignore                     # Deploy/retrieve filtering
├── sfdx-project.json                # Package dirs: force-app + unpackaged
├── config/
│   └── project-scratch-def.json
├── scripts/
│   └── apex/                        # Anonymous Apex scripts (not deployed)
├── docs/                            # Architecture docs (not deployed)
├── force-app/                       # *** MANAGED PACKAGE SOURCE ***
│   └── main/
│       └── default/
│           ├── classes/              # Apex classes + -meta.xml
│           ├── triggers/             # Apex triggers + -meta.xml
│           ├── lwc/                  # Lightning Web Components
│           ├── aura/                 # Aura (legacy only)
│           ├── objects/              # Custom Objects + Custom Metadata Types
│           ├── permissionsets/       # Permission Sets
│           ├── labels/              # Custom Labels
│           └── flows/               # Flows
├── unpackaged/                      # *** TEST/SAMPLE DATA (NOT in managed package) ***
│   └── main/
│       └── default/
│           ├── customMetadata/      # Custom Metadata records (test configs)
│           └── objects/             # Standard object customizations (e.g. Case)
```

**IMPORTANT:**
- All managed package metadata MUST live under `force-app/main/default/`.
- Test/sample data (CMDT records, Case customizations) lives under `unpackaged/main/default/`.
- The `unpackaged/` directory is registered in `sfdx-project.json` but is NOT part of the managed package.

---

# 19a. Deployment & Package Delivery

**All deployment commands, troubleshooting, and managed package delivery workflows are documented in:**

> **[CLAUDE_DEPLOYMENT.md](CLAUDE_DEPLOYMENT.md)**

AI agents MUST reference `CLAUDE_DEPLOYMENT.md` for deploy commands. Do NOT waste tokens figuring out deploy syntax.

Key sections in that file:
- Section 1: Deploy commands (quick reference)
- Section 2: Deployment order (dependency chain)
- Section 3: Troubleshooting (source tracking, conflicts, test gotchas)
- Section 5: Managed package versioning & customer delivery
- Section 7: Quick reference card
  
---

# 20. AI Agent Code Generation Rules

When generating features:

1 Design metadata first
2 Create selector
3 Create domain logic
4 Create service layer
5 Expose invocable methods
6 Build LWC UI
7 Write tests
8 **Deploy using commands from [CLAUDE_DEPLOYMENT.md](CLAUDE_DEPLOYMENT.md)** (deploy only changed files, not entire directories)
9 Run tests to validate

**Deployment rule:** After writing or modifying any file, immediately deploy ONLY that specific file using the exact commands from `CLAUDE_DEPLOYMENT.md`. Do NOT search for deploy commands, do NOT deploy entire directories for a single file change. This saves tokens and time.

Agents must prefer **extension over modification**.

---

# 21. Custom Labels & Internationalization (i18n)

**All user-facing strings MUST be externalized to Custom Labels — no hardcoded user-visible text in Apex or LWC.**

This is a hard rule for AppExchange Security Review compliance and multilingual support.

### 21.1 What MUST be a Custom Label

| Layer | Rule |
|---|---|
| **Apex** | All strings in `throw new AuraHandledException(...)`, `RoutingResult.failure(...)`, `RoutingResult.success(...)`, `outcome.errorMessage = ...`, and any user-visible message returned from `@AuraEnabled` / `@InvocableMethod` / `@HttpPost`. |
| **LWC JS** | All strings in `ShowToastEvent({ title, message })`, error fallbacks (`error.body?.message \|\| 'hardcoded'`), validation messages, and any string rendered into the template. |
| **LWC HTML** | All visible text — use `{label.xxx}` bindings, never inline strings. |

**What is NOT a Custom Label:**
- Status constants (`'Success'`, `'No_Match'`, `'Dry_Run'`) — these are system identifiers, not user text
- API names, field names, developer names
- Log/debug messages consumed only by `Logger` / `System.debug`
- Jest mock fixtures in `__tests__/*.test.js` (mocks are allowed to hardcode expected values)

### 21.2 Naming Convention

```
URE_<CATEGORY>_<CONTEXT>_<TYPE>
```

| Pattern | Example | Used For |
|---|---|---|
| `URE_ROUTING_*` | `URE_ROUTING_NO_AGENT_ERROR` | Routing engine errors |
| `URE_RESOLVER_*` | `URE_RESOLVER_LOCK_EXHAUSTED` | Assignment resolver |
| `URE_LOCK_*` | `URE_LOCK_RECORD_GONE` | Retry lock handler |
| `URE_MATCHER_*` | `URE_MATCHER_CAPABILITY_MISMATCH` | Agent matcher |
| `URE_PANEL_*` | `URE_PANEL_DEFER_FAILED` | Agent Work Panel |
| `URE_SCHEDULER_*` | `URE_SCHEDULER_JOB_NOT_FOUND` | Scheduled Job Controller |
| `URE_Wizard*` | `URE_WizardConfigActivated` | Setup Wizard (PascalCase legacy) |
| `URE_UNKNOWN_ERROR` | — | Shared generic fallback |

Keep the `URE_` prefix on every new label. Use SCREAMING_SNAKE_CASE for backend/error labels; PascalCase is acceptable for UI labels where that is the existing convention within a feature area.

### 21.3 Dynamic Placeholders

Custom Labels support `{0}`, `{1}`, `{2}` tokens. Never concatenate; always use `String.format()` in Apex and `.replace()` / template literals in LWC.

**Apex — correct:**
```apex
return RoutingResult.failure(
    request.recordId,
    String.format(
        System.Label.URE_ROUTING_CAPACITY_FULL_ERROR,
        new List<Object>{ currentLoad.intValue(), maxCapacity.intValue() }
    )
);
```

**Apex — WRONG:**
```apex
return RoutingResult.failure(
    request.recordId,
    'Agent has reached maximum capacity (' + currentLoad + '/' + maxCapacity + ').'
);
```

**LWC — correct:**
```javascript
import LABEL_STEP_OF from '@salesforce/label/c.URE_WizardStepOf';
// ...
get stepProgress() {
    return LABEL_STEP_OF
        .replace('{0}', String(this.currentStep))
        .replace('{1}', String(TOTAL_STEPS));
}
```

**Label value with tokens:**
```xml
<value>Agent has reached maximum capacity ({0}/{1}). Close or reassign existing items before requesting new work.</value>
```

### 21.4 Label Metadata Requirements

Every `<labels>` entry in `CustomLabels.labels-meta.xml` MUST include:

```xml
<labels>
    <fullName>URE_ROUTING_NO_AGENT_ERROR</fullName>
    <language>en_US</language>
    <protected>true</protected>
    <shortDescription>No active Agent record for current user</shortDescription>
    <value>No active Agent record found for the current user...</value>
</labels>
```

- `<protected>true</protected>` — required for managed package labels (subscribers cannot override).
- `<shortDescription>` — describes **what the label is for**, not the content. Translators see this.
- `<language>en_US</language>` — base language. Additional translations live in `translations/` files.
- Group related labels under a section comment: `<!-- ══ Routing Engine: Error Messages ══ -->`

### 21.5 LWC Import Pattern

All labels bind to a single `label` property on the component:

```javascript
import LABEL_NEXT from '@salesforce/label/c.URE_WizardNext';
import LABEL_FINISH from '@salesforce/label/c.URE_WizardFinish';
import LABEL_TIMEOUT from '@salesforce/label/c.URE_WizardDeployTimeout';

export default class UreSetupWizard extends LightningElement {
    label = {
        next: LABEL_NEXT,
        finish: LABEL_FINISH
    };
    // Use in template: {label.next}
    // Use in code: this.deployError = LABEL_TIMEOUT;
}
```

For Jest tests, mock labels with `{ virtual: true }`:

```javascript
jest.mock('@salesforce/label/c.URE_Routing', () => ({ default: 'Routing...' }), { virtual: true });
```

---

# 22. Apex Coding Style

### 22.1 Error Message Construction

**Never build user-visible error strings inline.** Every error message that can reach a caller (Flow, LWC, REST client) must come from a Custom Label.

| Method | Rule |
|---|---|
| `RoutingResult.failure(id, msg)` | `msg` must be `System.Label.*` or `String.format(System.Label.*, args)` |
| `throw new AuraHandledException(msg)` | `msg` must be `System.Label.*` |
| `outcome.errorMessage = ...` | Must be `System.Label.*` or `String.format(System.Label.*, args)` |
| `System.debug(msg)` / `Logger.error(msg)` | Hardcoded English strings ARE allowed (not user-facing) |

### 22.2 Factory Methods for Value Objects

Inner-class value objects (outcomes, results) cannot have static methods in Apex. Put factories on the outer class:

```apex
public class AssignmentResolver {
    public class AssignmentOutcome {
        public Id recordId { get; private set; }
        public Boolean success { get; private set; }
        public String errorMessage { get; private set; }
        @TestVisible private AssignmentOutcome() {}
    }

    private static AssignmentOutcome outcomeNoMatch(Integer candidateCount) {
        AssignmentOutcome o = new AssignmentOutcome();
        o.success = false;
        o.errorMessage = System.Label.URE_RESOLVER_NO_MATCH;
        return o;
    }
}
```

### 22.3 Null-Safe Numerics

Custom number fields return `null` when empty. Always coalesce before arithmetic or comparison:

```apex
Decimal currentLoad = currentAgent.Current_Load__c != null
    ? currentAgent.Current_Load__c : 0;
```

### 22.4 SOQL & DML Security

Every SOQL and DML statement touching subscriber data must enforce user mode:

```apex
Database.update(record, false, AccessLevel.USER_MODE);

List<SObject> rows = Database.queryWithBinds(
    soql,
    bindMap,
    AccessLevel.USER_MODE
);
```

Use bind variables via `Map<String, Object>` — never concatenate user input into SOQL.

### 22.5 Governor-Aware Patterns

- Pre-load reference data into transaction cache once; subsequent calls read from cache (0 SOQL).
- Fail-fast read-only gates (Phase 1–3) before any DML (Phase 4+).
- Document per-method SOQL/DML cost in the class-level ApexDoc.

### 22.6 Class-Level Documentation

Every class MUST have a `@description` ApexDoc block and a `@group` tag (`Entry`, `Orchestrator`, `Worker`, `Selector`, `Service`, `UI`, `Domain`).

```apex
/**
 * @description Stateless orchestrator — delegates all SOQL/DML to workers.
 *              Phases: 1-Validate, 2-AgentGate, 3-LoadConfigs, 4-ProcessBundles,
 *              5-AuditFlush, 6-Return. Typical budget: ~5 SOQL + 2 DML.
 * @group Orchestrator
 */
public with sharing class RoutingEngine { ... }
```

### 22.7 Exception Handling at Integration Surfaces

Entry-point classes (`@InvocableMethod`, `@HttpPost`, `@AuraEnabled` in global services) must NEVER throw to callers. Wrap everything in try/catch and return a structured `RoutingResult.failure(...)` with a `System.Label` message.

### 22.8 Private Static Constant Naming

- `FALLBACK_*` for Custom Settings safety nets (NOT `DEFAULT_*`)
- `CLS` for class name used in Logger calls
- `SCREAMING_SNAKE_CASE` for all static finals

```apex
private static final String CLS = 'RoutingEngine';
private static final Integer FALLBACK_DAYS = 30;
```

---

# 23. Pull Request Validation Checklist

Before committing code ensure:

- triggers contain no logic
- SOQL centralized in selectors
- CRUD/FLS enforced (AccessLevel.USER_MODE on every SOQL/DML)
- code bulkified
- metadata packaging safe
- no hardcoded IDs
- namespace safe
- tests included
- **no hardcoded user-facing strings — all messages use `System.Label.*` (Apex) or `@salesforce/label/c.*` (LWC)** (see §21)
- **dynamic values use `String.format()` / `.replace()`, never string concatenation** (see §21.3)
- **every new Custom Label has `<protected>true</protected>` and a meaningful `<shortDescription>`** (see §21.4)
- no hardcoded tunable values — use Custom Settings with `FALLBACK_*` constants (see §1a)



