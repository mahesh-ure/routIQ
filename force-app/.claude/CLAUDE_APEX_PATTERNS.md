# CLAUDE_APEX_PATTERNS.md
Salesforce Apex Architecture Patterns for AI Agents

This document defines the Apex development standards used in this repository.

Agents must follow **Salesforce Enterprise Patterns** suitable for large-scale AppExchange products.

---

# Apex Architecture Layers

Apex code must follow a layered architecture:

Domain Layer
Business rules for objects

Service Layer
Application workflows

Selector Layer
SOQL queries

Utility Layer
Reusable helpers

---

# Trigger Framework Rules

All objects must have **one trigger only**.

Trigger must delegate logic.

Example:

trigger AccountTrigger on Account (
    before insert,
    before update,
    after insert,
    after update
) {
    TriggerDispatcher.dispatch();
}

Triggers must never contain:

- business logic
- queries
- DML

---

# Trigger Handler Pattern

Handlers process trigger events.

Example:

public with sharing class AccountTriggerHandler {

    public static void beforeInsert(List<Account> records) {

        AccountDomain.validate(records);

    }

}

---

# Domain Layer Pattern

Domain classes hold business rules.

Example:

public class AccountDomain {

    public static void validate(List<Account> records){

        for(Account acc : records){

            if(acc.Name == null){
                acc.addError('Name is required');
            }

        }

    }

}

Rules:

Domain classes must:

- be bulk safe
- contain object-specific logic
- avoid SOQL where possible

---

# Selector Pattern

Selectors encapsulate queries.

Example:

public with sharing class AccountSelector {

    public static List<Account> selectByIds(Set<Id> ids){

        return [
            SELECT Id, Name, Industry
            FROM Account
            WHERE Id IN :ids
        ];

    }

}

Benefits:

- reusable queries
- easier testability
- centralized performance optimization

---

# Service Layer Pattern

Services orchestrate workflows.

Example:

public with sharing class LeadRoutingService {

    public static void routeLeads(List<Lead> leads){

        List<User> agents =
            UserSelector.getAvailableAgents();

    }

}

Rules:

Services must:

- support bulk
- orchestrate logic
- not contain UI concerns

---

# Bulkification Rules

All Apex must support bulk operations.

Bad:

Account a = Trigger.new[0];

Good:

for(Account acc : Trigger.new)

Never:

- run SOQL inside loops
- run DML inside loops

---

# Asynchronous Patterns

Use async processing when necessary.

Tools:

Queueable Apex  
Batch Apex  
Platform Events  
Future Methods (only for legacy)

Preferred order:

Queueable → Platform Events → Batch

---

# Test Class Patterns

Tests must include:

- bulk tests
- negative tests
- permission tests

Example structure:

TestDataFactory
AccountServiceTest
AccountSelectorTest
AccountDomainTest

---

# Logging Pattern

Use centralized logging utilities.

Example:

Logger.info()
Logger.warn()
Logger.error()

Avoid System.debug() in production code.