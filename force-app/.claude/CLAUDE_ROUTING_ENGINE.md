# CLAUDE_ROUTING_ENGINE.md
Metadata Driven Routing Engine Architecture

This application includes a dynamic routing engine used for:

- lead routing
- case assignment
- work distribution
- task assignment

The engine must be metadata driven.

---

# Routing Metadata

Routing rules are stored in Custom Metadata.

Routing_Rule__mdt

Fields:

Object_Name__c
Filter_Condition__c
Target_User_Field__c
Priority__c
Active__c

---

# Routing Engine Flow

Record Created
↓
Routing Service
↓
Evaluate Rules
↓
Select Target User
↓
Assign Record

---

# Routing Service Example

public with sharing class RoutingService {

    public static void routeRecords(List<SObject> records){

        List<Routing_Rule__mdt> rules =
            RoutingRuleSelector.getActiveRules();

    }

}

---

# Assignment Strategies

The engine must support:

Round Robin  
Load Balancing  
Skill Based Routing  
Region Based Routing  

Strategy selection should be metadata driven.

---

# User Attribute Routing

Users may contain routing attributes.

Example:

User.Region__c  
User.Team__c  
User.Skill_Level__c  

Routing engine must evaluate user attributes.

---

# Failover Strategy

If routing fails:

Fallback to queue assignment.

Queues defined via metadata.

---

# Performance Considerations

Routing must support:

- bulk record processing
- minimal SOQL queries
- caching metadata