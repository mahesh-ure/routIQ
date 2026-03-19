# CLAUDE_SECURITY_REVIEW.md
Salesforce AppExchange Security Review Guidelines

All code generated in this repository must pass Salesforce Security Review.

---

# SOQL Injection Protection

Never concatenate queries.

Bad:

String query =
 'SELECT Id FROM Account WHERE Name = ' + name;

Good:

SELECT Id FROM Account WHERE Name = :name

---

# CRUD and FLS Enforcement

All Apex must enforce permissions.

Use:

Security.stripInaccessible()

or

Schema.sObjectType.Account.isAccessible()

---

# Cross Site Scripting Protection

LWC must sanitize user input.

Never render raw HTML.

Avoid:

lwc:dom="manual"

unless necessary.

---

# Secure Callouts

All external callouts must use:

Named Credentials

Never store secrets in:

- Custom Metadata
- Custom Settings
- Apex code

---

# Session Security

Never expose:

- session IDs
- OAuth tokens

---

# Data Exposure Rules

Never expose sensitive fields via Apex APIs without permission checks.

Examples:

SSN
Credit card data
PII

---

# Static Code Analysis

All code must pass:

Salesforce Code Analyzer  
PMD rules  
Security scanners