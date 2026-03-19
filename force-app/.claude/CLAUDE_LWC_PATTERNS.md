# CLAUDE_LWC_PATTERNS.md
Lightning Web Component Architecture for AI Agents

This repository uses Lightning Web Components as the primary UI framework.

Agents must generate LWCs following these standards.

---

# Component Structure

Each component must include:

component.html  
component.js  
component.js-meta.xml  

Example:

lwc/
  routingWorkspace/
     routingWorkspace.html
     routingWorkspace.js
     routingWorkspace.js-meta.xml

---

# Component Responsibilities

LWC should focus on:

- UI rendering
- user interaction
- calling Apex services

LWC must not contain:

- business logic
- complex algorithms
- data validation rules

---

# Data Access Priority

Preferred order:

1 Lightning Data Service  
2 UI API  
3 Apex  

Use Apex only when necessary.

---

# Apex Integration

Use @wire whenever possible.

Example:

@wire(getAccounts)
accounts;

Use imperative calls for:

- mutations
- transactions
- button actions

---

# Event Communication

Use events for component communication.

Child → Parent

CustomEvent

Example:

this.dispatchEvent(
  new CustomEvent('refresh')
);

---

# Performance Rules

Avoid:

- excessive Apex calls
- unnecessary rerenders
- large DOM trees

Use:

- pagination
- lazy loading
- virtual lists

---

# Security Rules

All UI must respect:

- field-level security
- object permissions

Never display fields users cannot access.

---

# Naming Conventions

Components must use camelCase.

Examples:

leadRouter
agentWorkspace
routingMonitor