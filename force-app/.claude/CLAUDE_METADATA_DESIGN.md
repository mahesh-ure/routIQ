# CLAUDE_METADATA_DESIGN.md
Metadata Driven Architecture Standards

This system relies heavily on metadata configuration.

Agents must design metadata before writing Apex.

---

# Metadata Types Used

Routing_Rule__mdt
Feature_Flag__mdt
Query_Template__mdt
Assignment_Strategy__mdt

---

# Metadata First Development

Feature development order:

1 Design metadata
2 Create selectors
3 Build services
4 Create UI
5 Write tests

---

# Feature Flag Pattern

Feature flags enable safe rollout.

Example metadata:

Feature_Flag__mdt

Fields:

Feature_Name__c
Enabled__c
Min_Package_Version__c

Example usage:

if(FeatureFlagService.isEnabled('ADV_ROUTING')){
   runAdvancedRouting();
}

---

# Query Template Metadata

Dynamic queries stored in metadata.

Fields:

Object_API_Name__c
Field_List__c
Where_Clause__c
Order_By__c

Example usage:

DynamicQueryService.runQuery(templateName)

---

# Upgrade Safe Design

Never:

- rename metadata fields
- delete metadata
- change API names

Instead:

- version metadata
- add new fields
- deprecate old ones