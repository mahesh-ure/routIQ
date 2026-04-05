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

# 21. Pull Request Validation Checklist

Before committing code ensure:

- triggers contain no logic
- SOQL centralized in selectors
- CRUD/FLS enforced
- code bulkified
- metadata packaging safe
- no hardcoded IDs
- namespace safe
- tests included



