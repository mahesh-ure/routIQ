# URE Execution Flow: "Next Best Action" Button Clicked
**Version:** 6.0 (Skill Bundle Architecture)  
**Audience:** Junior Developer  
**Perspective:** What happens *inside the engine* from click to assignment  
**Last Updated:** April 2026

---

## Executive Summary

When an agent clicks **"Next Best Action"**, here's what happens under the hood:

```
User clicks button
    ↓
LWC calls RoutingService.getNextRecord() [Apex]
    ↓
RoutingService validates & delegates to RoutingEngine
    ↓
RoutingEngine executes 6 phases (fail-fast, then DML)
    ↓
Record gets assigned to agent
    ↓
LWC shows success toast
```

This document walks you through **every class and method**, in order.

---

## The Complete Flow: Step-by-Step

### Step 0: Agent Clicks Button (LWC)

**File:** `force-app/main/default/lwc/ureAgentWorkPanel/ureAgentWorkPanel.js`  
**Method:** `handleGetNextWork()`

```javascript
// In the LWC component
async handleGetNextWork() {
    this.isLoading = true;
    try {
        // Call Apex method (imperative, NOT @wire)
        const result = await getNextWork({
            objectApiName: 'Case',           // Which object?
            recordId: null,                  // Null = any case
            configDeveloperName: 'Case_Support_Routing'  // Which config?
        });
        
        if (result.success) {
            // Show "Record assigned!" toast
            showToast('Success', 'Case assigned!', 'success');
        } else {
            // Show error
            showToast('Error', result.errorMessage, 'error');
        }
    } finally {
        this.isLoading = false;
    }
}
```

**What it does:**
- Sets loading state (button shows spinner)
- Calls the Apex method
- Waits for response
- Shows success or error message

---

### Step 1: RoutingService.getNextRecord() [Entry Point]

**File:** `force-app/main/default/classes/RoutingService.cls`  
**Method:** `getNextRecord()` (lines 64-77)  
**Annotation:** `@AuraEnabled`

```apex
@AuraEnabled
global static RoutingResult getNextRecord(
    String objectApiName,
    String recordId,
    String configDeveloperName,
    Boolean dryRun
) {
    RoutingRequest request = new RoutingRequest();
    request.objectApiName = objectApiName;
    request.recordId = recordId;
    request.configDeveloperName = configDeveloperName;
    request.dryRun = dryRun;
    
    return executeSingle(request, 'LWC');
}
```

**What it does:**
- Converts LWC parameters into a `RoutingRequest` DTO
- Calls `executeSingle()` (common dispatcher for all entry points: Flow, REST, LWC)

**Return:** `RoutingResult` object with:
- `success: Boolean` — Did it work?
- `recordId: Id` — Which record was assigned?
- `recordName: String` — Record name for display
- `errorMessage: String` — Why did it fail?

---

### Step 2: RoutingService.executeSingle() [Common Dispatcher]

**File:** `force-app/main/default/classes/RoutingService.cls`  
**Method:** `executeSingle()` (lines 80-110)

```apex
private static RoutingResult executeSingle(
    RoutingRequest request,
    String entryPoint  // 'LWC', 'Flow', 'REST'
) {
    // Initialize logging
    Logger.init(entryPoint, UserInfo.getUserId());
    
    try {
        // Get current user's agent record
        Id agentUserId = UserInfo.getUserId();
        
        // Delegate to orchestrator
        RoutingResult result = RoutingEngine.execute(
            request,
            agentUserId,
            entryPoint
        );
        
        return result;
        
    } catch (Exception ex) {
        Logger.error('Unexpected error in routing')
            .withException(ex)
            .log();
        return RoutingResult.failure(
            request.recordId,
            System.Label.URE_UNKNOWN_ERROR
        );
    }
}
```

**What it does:**
- Wraps the routing call in try/catch (never throws to LWC)
- Gets current user ID
- Delegates to `RoutingEngine.execute()` for the real work
- If exception: logs it, returns failure result

**Key:** All 3 entry points (Flow, REST, LWC) converge here.

---

### Step 3: RoutingEngine.execute() [Orchestrator — The Brain]

**File:** `force-app/main/default/classes/RoutingEngine.cls`  
**Method:** `execute()` (lines 14-150+)  
**Group:** Orchestrator

This is the **core of URE**. It orchestrates 6 phases.

```apex
public static RoutingResult execute(
    RoutingRequest request,
    Id agentUserId,
    String entryPoint
) {
    // Record request time for analytics
    Long requestStartMs = System.currentTimeMillis();
    
    // ═══════════════════════════════════════════════════════════════
    // PHASE 1: Validate Request (0 SOQL, 0 DML) — FAIL-FAST
    // ═══════════════════════════════════════════════════════════════
    List<String> validationErrors = request.validate();
    if (!validationErrors.isEmpty()) {
        Logger.warn('Request validation failed')
            .log();
        return RoutingResult.failure(
            request.recordId,
            System.Label.URE_ROUTING_VALIDATION_FAILED
        );
    }
    
    // ═══════════════════════════════════════════════════════════════
    // PHASE 2: Agent Gate (fail-fast, read-only) — CHECK AGENT ELIGIBILITY
    // ═══════════════════════════════════════════════════════════════
    
    // Get all active agents (cached across transaction)
    Map<Id, Agent__c> agentMap = AgentCapabilitySelector.getActiveAgentsByUserId();
    Agent__c currentAgent = agentMap.get(agentUserId);
    
    // Does agent exist and is active?
    if (currentAgent == null) {
        Logger.warn('No active Agent__c record for user')
            .log();
        return RoutingResult.failure(
            request.recordId,
            System.Label.URE_ROUTING_NO_AGENT_ERROR
        );
    }
    
    // Is agent at capacity?
    Decimal currentLoad = currentAgent.Current_Load__c != null 
        ? currentAgent.Current_Load__c : 0;
    Decimal maxCapacity = currentAgent.Max_Capacity__c != null 
        ? currentAgent.Max_Capacity__c : 0;
    
    if (maxCapacity > 0 && currentLoad >= maxCapacity) {
        Logger.warn('Agent at capacity')
            .log();
        return RoutingResult.failure(
            request.recordId,
            String.format(
                System.Label.URE_ROUTING_CAPACITY_FULL_ERROR,
                new List<Object>{currentLoad.intValue(), maxCapacity.intValue()}
            )
        );
    }
    
    // Is agent online?
    String availStatus = (String) currentAgent.get('Availability_Status__c');
    if (availStatus == 'Away' || availStatus == 'Offline') {
        Logger.warn('Agent not available')
            .log();
        return RoutingResult.failure(
            request.recordId,
            String.format(
                System.Label.URE_ROUTING_AVAILABILITY_ERROR,
                new List<Object>{availStatus}
            )
        );
    }
    
    Logger.info('Agent gate passed')
        .log();
    
    // ═══════════════════════════════════════════════════════════════
    // PHASE 3: Load Configuration (0 SOQL, uses platform-cached CMDT)
    // ═══════════════════════════════════════════════════════════════
    
    // ConfigLoader reads ALL CMDT in one pass, groups by config
    List<ConfigBundle> allConfigs = ConfigLoader.loadActive();
    
    // RuleEvaluator filters configs to only ones that match this request
    RuleEvaluator.EvaluationResult evaluation = 
        RuleEvaluator.evaluate(allConfigs, request);
    
    List<ConfigBundle> applicableBundles = evaluation.applicableBundles;
    
    if (applicableBundles.isEmpty()) {
        Logger.warn('No applicable routing configs')
            .log();
        return RoutingResult.failure(
            request.recordId,
            System.Label.URE_ROUTING_NO_CONFIG_MATCH
        );
    }
    
    Logger.info('Loaded ' + applicableBundles.size() + ' applicable configs')
        .log();
    
    // ═══════════════════════════════════════════════════════════════
    // PHASE 4: Process Bundles & Query Candidates (SOQL + DML)
    // ═══════════════════════════════════════════════════════════════
    
    // Pre-load all agent skills (2-3 SOQL on first call, cached thereafter)
    Map<Id, Map<String, Set<String>>> capabilityMap =
        AgentCapabilitySelector.getCapabilityMap();
    
    // For each applicable config, find & assign ONE candidate
    for (ConfigBundle bundle : applicableBundles) {
        
        // Sub-phase 4a: Check agent skills match this config's requirements
        AgentMatcher.MatchResult agentMatch = AgentMatcher.evaluate(
            null,  // We're checking agent's skills exist
            bundle.skillMappings,
            agentUserId,
            bundle.config.DeveloperName
        );
        
        if (!agentMatch.matched) {
            Logger.warn('Agent does not match required skills for this config')
                .log();
            continue;  // Try next config
        }
        
        // Sub-phase 4b: Build candidate query
        QuerySpec querySpec = DynamicQueryBuilder.build(
            bundle,
            capabilityMap.get(agentUserId),
            currentAgent
        );
        
        // Sub-phase 4c: Execute query to find candidates
        List<SObject> candidates = CandidateSelector.query(querySpec);
        
        if (candidates.isEmpty()) {
            Logger.info('No candidates found for config')
                .log();
            continue;  // Try next config
        }
        
        Logger.info('Found ' + candidates.size() + ' candidates')
            .log();
        
        // Sub-phase 4d: Try to assign each candidate (with lock retries)
        AssignmentResolver.AssignmentOutcome outcome = 
            AssignmentResolver.resolve(
                candidates.get(0),  // First candidate (already sorted by priority)
                agentUserId,
                bundle.config,
                agentMap.get(agentUserId),
                candidates.size()
            );
        
        // Sub-phase 4e: Audit log the result
        AuditLogger.log(
            request.recordId,
            bundle.config.DeveloperName,
            outcome,
            request.dryRun
        );
        
        // If assignment succeeded, return immediately
        if (outcome.success) {
            Logger.info('Assignment successful')
                .log();
            
            return RoutingResult.success(
                outcome.recordId,
                candidates.get(0).get('Name')
            );
        }
    }
    
    // ═══════════════════════════════════════════════════════════════
    // PHASE 5: No Success — Return Failure
    // ═══════════════════════════════════════════════════════════════
    
    Logger.warn('All configs tried, no assignment succeeded')
        .log();
    
    return RoutingResult.failure(
        request.recordId,
        System.Label.URE_ROUTING_NO_AGENT_ERROR
    );
}
```

**Key Points:**
1. **Phases 1-3** are read-only, fail-fast. If any check fails, returns immediately without DML.
2. **Phase 4** is where DML happens. If exceptions occur, the transaction rolls back atomically.
3. **Early exits** at each phase save time and SOQL queries.

---

### Step 4a: AgentCapabilitySelector.getActiveAgentsByUserId()

**File:** `force-app/main/default/classes/AgentCapabilitySelector.cls`  
**Method:** `getActiveAgentsByUserId()` (lines 64-97)

```apex
public static Map<Id, Agent__c> getActiveAgentsByUserId() {
    // Return cached if already loaded
    if (cachedAgents != null) {
        return cachedAgents;
    }
    
    // SOQL: Select all active agents
    String soql = 'SELECT Id, User__c, User__r.Name, Is_Active__c, '
        + 'Max_Capacity__c, Current_Load__c, Last_Assigned__c, '
        + 'Availability_Status__c '
        + 'FROM Agent__c '
        + 'WHERE Is_Active__c = :isActive '
        + 'AND User__c != NULL';
    
    Map<String, Object> binds = new Map<String, Object>{
        'isActive' => true
    };
    
    List<SObject> results = Database.queryWithBinds(
        soql, binds, AccessLevel.USER_MODE  // FLS/sharing enforced
    );
    
    // Build map: User__c → Agent__c
    cachedAgents = new Map<Id, Agent__c>();
    for (SObject rec : results) {
        Agent__c agent = (Agent__c) rec;
        cachedAgents.put(agent.User__c, agent);
    }
    
    return cachedAgents;
}
```

**What it does:**
- Queries all active Agent__c records
- Maps them by User Id (for fast lookup)
- Caches result (0 SOQL on subsequent calls within same transaction)

**Governor Cost:** 1 SOQL on first call, 0 on subsequent calls.

---

### Step 4b: ConfigLoader.loadActive()

**File:** `force-app/main/default/classes/ConfigLoader.cls`  
**Method:** `loadActive()` (lines 28-130)

```apex
public static List<ConfigBundle> loadActive() {
    
    // Step 1: Read all CMDT (0 SOQL — platform-cached)
    Map<String, Routing_Config__mdt> allConfigs =
        RoutingConfigSelector.getAllConfigs();
    Map<String, Routing_Condition__mdt> allConditions =
        RoutingConfigSelector.getAllConditions();
    Map<String, Routing_Priority__mdt> allPriorities =
        RoutingConfigSelector.getAllPriorities();
    Map<String, Routing_Skill_Mapping__mdt> allSkillMappings =
        RoutingConfigSelector.getAllSkillMappings();
    
    // Step 2: Group conditions by parent config
    Map<String, List<Routing_Condition__mdt>> conditionsByConfig =
        new Map<String, List<Routing_Condition__mdt>>();
    for (Routing_Condition__mdt cond : allConditions.values()) {
        if (cond.Is_Active__c != true) continue;
        
        String parentDevName = configIdToDevName.get(cond.Routing_Config__c);
        if (parentDevName == null) continue;
        
        if (!conditionsByConfig.containsKey(parentDevName)) {
            conditionsByConfig.put(parentDevName, new List<Routing_Condition__mdt>());
        }
        conditionsByConfig.get(parentDevName).add(cond);
    }
    
    // Step 3: Group priorities by parent config
    Map<String, List<Routing_Priority__mdt>> prioritiesByConfig =
        new Map<String, List<Routing_Priority__mdt>>();
    // ... similar logic ...
    
    // Step 4: Group skill mappings by parent config (v6)
    Map<String, List<Routing_Skill_Mapping__mdt>> skillMappingsByConfig =
        new Map<String, List<Routing_Skill_Mapping__mdt>>();
    // ... similar logic ...
    
    // Step 5: Build ConfigBundles
    List<ConfigBundle> bundles = new List<ConfigBundle>();
    for (Routing_Config__mdt cfg : allConfigs.values()) {
        if (cfg.Active__c != true) continue;
        
        ConfigBundle bundle = new ConfigBundle();
        bundle.config = cfg;
        bundle.conditions = conditionsByConfig.get(cfg.DeveloperName) ?? new List<Routing_Condition__mdt>();
        bundle.priorities = prioritiesByConfig.get(cfg.DeveloperName) ?? new List<Routing_Priority__mdt>();
        bundle.skillMappings = skillMappingsByConfig.get(cfg.DeveloperName) ?? new List<Routing_Skill_Mapping__mdt>();
        
        bundles.add(bundle);
    }
    
    // Sort by Priority_Weight__c (higher weight = check first)
    bundles.sort();
    
    return bundles;
}
```

**What it does:**
- Reads all CMDT records (cached by Salesforce platform)
- Groups conditions, priorities, and skill mappings by config
- Wraps each config in a `ConfigBundle` object
- Returns sorted list (configs with higher Priority_Weight checked first)

**Governor Cost:** 0 SOQL (CMDT.getAll() is platform-cached, not a SOQL call).

---

### Step 4c: RuleEvaluator.evaluate()

**File:** `force-app/main/default/classes/RuleEvaluator.cls`  
**Method:** `evaluate()` (lines 68-150)

```apex
public static EvaluationResult evaluate(
    List<ConfigBundle> bundles,
    RoutingRequest request
) {
    EvaluationResult result = new EvaluationResult();
    
    for (ConfigBundle bundle : bundles) {
        Routing_Config__mdt config = bundle.config;
        
        // Check 1: Does config object match request object?
        if (config.Object_API_Name__c != request.objectApiName) {
            continue;  // Skip this config
        }
        
        // Check 2: If request specified a config name, does it match?
        if (request.configDeveloperName != null &&
            request.configDeveloperName != config.DeveloperName) {
            continue;  // Skip this config
        }
        
        // Check 3: If request specified a record type, does config match?
        if (request.recordTypeDevName != null &&
            request.recordTypeDevName != config.Record_Type_Dev_Name__c) {
            continue;  // Skip this config
        }
        
        // Check 4: Validate bundle is well-formed
        List<String> validationErrors = validateBundle(bundle);
        if (!validationErrors.isEmpty()) {
            result.validationWarnings.add(
                'Config ' + config.DeveloperName + ' failed validation: ' + 
                String.join(validationErrors, '; ')
            );
            continue;  // Skip malformed config
        }
        
        // This bundle is applicable!
        result.applicableBundles.add(bundle);
    }
    
    return result;
}
```

**What it does:**
- Checks if each config applies to the request (object name, record type, config name match)
- Validates each config's structure
- Returns only applicable configs

**Governor Cost:** 0 SOQL, pure in-memory filtering.

---

### Step 4d: AgentCapabilitySelector.getCapabilityMap()

**File:** `force-app/main/default/classes/AgentCapabilitySelector.cls`  
**Method:** `getCapabilityMap()` (lines 140-200+)

This is the **skill bundle merger**.

```apex
public static Map<Id, Map<String, Set<String>>> getCapabilityMap() {
    // Returns transaction-cached map of agent skills
    // Structure: AgentId → SkillDimension → Values
    // Example: John → Language → {en_US, fr_CA}
    
    if (cachedCapabilityMap != null) {
        return cachedCapabilityMap;
    }
    
    // Load agents, assignments, bundle entries (3 SOQLs, cached)
    Map<Id, Agent__c> agents = getActiveAgentsByUserId();  // 1 SOQL or 0 (cached)
    List<Agent_Skill_Assignment__c> assignments = getActiveAssignments();  // 1 SOQL or 0
    List<Skill_Bundle_Entry__c> entries = getSkillBundleEntries();  // 1 SOQL or 0 (platform-cached)
    
    // Build map: BundleId → [Entry1, Entry2, ...]
    Map<Id, List<Skill_Bundle_Entry__c>> entriesByBundle = new Map<Id, List<Skill_Bundle_Entry__c>>();
    for (Skill_Bundle_Entry__c entry : entries) {
        Id bundleId = entry.Skill_Bundle__c;
        if (!entriesByBundle.containsKey(bundleId)) {
            entriesByBundle.put(bundleId, new List<Skill_Bundle_Entry__c>());
        }
        entriesByBundle.get(bundleId).add(entry);
    }
    
    // Build final map: AgentId → Skill → Values (UNION of all bundles)
    cachedCapabilityMap = new Map<Id, Map<String, Set<String>>>();
    
    for (Agent_Skill_Assignment__c assignment : assignments) {
        Id agentId = assignment.Agent__c;
        Id bundleId = assignment.Skill_Bundle__c;
        
        if (!cachedCapabilityMap.containsKey(agentId)) {
            cachedCapabilityMap.put(agentId, new Map<String, Set<String>>());
        }
        
        // UNION: merge entries from this bundle into agent's skill map
        List<Skill_Bundle_Entry__c> bundleEntries = entriesByBundle.get(bundleId);
        if (bundleEntries != null) {
            for (Skill_Bundle_Entry__c entry : bundleEntries) {
                String skillDimension = entry.Agent_Skill__r.DeveloperName;
                
                if (!cachedCapabilityMap.get(agentId).containsKey(skillDimension)) {
                    cachedCapabilityMap.get(agentId).put(
                        skillDimension,
                        new Set<String>()
                    );
                }
                
                // Add this entry's values to the set (UNION logic)
                Set<String> values = entry.Skill_Values__c.split(',');
                cachedCapabilityMap.get(agentId).get(skillDimension).addAll(values);
            }
        }
    }
    
    return cachedCapabilityMap;
}
```

**What it does (Skill Bundle UNION):**

Example:
- Agent John has 2 bundles: "Support_Standard" and "Bilingual"
- Support_Standard has: Language={en_US}, ProductLine={General}
- Bilingual has: Language={es_MX, fr_CA}
- **Result:** John's map = Language={en_US, es_MX, fr_CA}, ProductLine={General}

**Governor Cost:** 2-3 SOQL on first call, 0 on subsequent calls within transaction.

---

### Step 4e: DynamicQueryBuilder.build()

**File:** `force-app/main/default/classes/DynamicQueryBuilder.cls`  
**Method:** `build()` (lines 30-120)

This builds the SOQL query that finds candidate records.

```apex
public static QuerySpec build(
    ConfigBundle bundle,
    Map<String, Set<String>> agentSkills,
    Agent__c agent
) {
    QuerySpec spec = new QuerySpec();
    spec.objectApiName = bundle.config.Object_API_Name__c;
    
    // Step 1: Build SELECT clause
    String selectClause = 'SELECT ' + bundle.config.Select_Fields__c;
    
    // Step 2: Build WHERE clause from conditions
    List<String> whereParts = new List<String>();
    Map<String, List<Object>> bindMap = new Map<String, List<Object>>();
    
    for (Routing_Condition__mdt cond : bundle.conditions) {
        String fieldName = cond.Field_API_Name__c;
        String operator = cond.Operator__c;
        
        // ConditionBinder translates operator to SOQL syntax
        ConditionBinder.WhereClause whereClause = 
            ConditionBinder.bind(fieldName, operator, cond.Values__c);
        
        whereParts.add(whereClause.clause);  // e.g., "Status != :bindStatus"
        bindMap.putAll(whereClause.binds);   // e.g., {'bindStatus' => 'Closed'}
    }
    
    String whereClause = '(' + String.join(whereParts, ' AND ') + ')';
    
    // Step 3: Build ORDER BY clause from priorities
    List<String> orderParts = new List<String>();
    for (Routing_Priority__mdt pri : bundle.priorities) {
        String direction = pri.Sort_Direction__c;  // ASC or DESC
        orderParts.add(pri.Field_API_Name__c + ' ' + direction);
    }
    String orderByClause = 'ORDER BY ' + String.join(orderParts, ', ');
    
    // Step 4: Assemble full SOQL
    String soql = selectClause + ' FROM ' + spec.objectApiName + 
                  ' WHERE ' + whereClause + ' ' + orderByClause +
                  ' LIMIT ' + bundle.config.Candidate_Limit__c;
    
    spec.soql = soql;
    spec.bindMap = bindMap;
    
    return spec;
}
```

**Example Generated SOQL:**
```sql
SELECT Id, Subject, Priority, RecordTypeId, Status, Language__c 
FROM Case 
WHERE (Status != :bindStatus AND Priority IN :bindPriority) 
ORDER BY Current_Load__c ASC, Last_Assigned__c ASC
LIMIT 200
```

**Governor Cost:** 0 SOQL (pure string building).

---

### Step 4f: CandidateSelector.query()

**File:** `force-app/main/default/classes/CandidateSelector.cls`  
**Method:** `query()` (lines 24-44)

```apex
public static List<SObject> query(QuerySpec spec) {
    // Execute the SOQL built by DynamicQueryBuilder
    List<SObject> results = Database.queryWithBinds(
        spec.soql,
        spec.bindMap,
        AccessLevel.USER_MODE  // Enforce FLS + sharing
    );
    
    Logger.info('Candidate query executed')
        .log();
    
    return results;
}
```

**What it does:**
- Executes the SOQL query
- Enforces field-level security (USER_MODE)
- Returns matching candidates (already sorted by priority)

**Governor Cost:** 1 SOQL.

---

### Step 4g: AgentMatcher.evaluate()

**File:** `force-app/main/default/classes/AgentMatcher.cls`  
**Method:** `evaluate()` (lines 50-150)

**Purpose:** Does the agent's skills match the work record's skill requirements?

```apex
public static MatchResult evaluate(
    SObject workRecord,
    List<Routing_Skill_Mapping__mdt> skillMappings,
    Id agentUserId,
    String configDevName
) {
    MatchResult result = new MatchResult();
    
    // Get agent's skills from the capability map
    Map<Id, Map<String, Set<String>>> capabilityMap = 
        AgentCapabilitySelector.getCapabilityMap();
    Map<String, Set<String>> agentSkills = 
        capabilityMap.get(agentUserId);
    
    if (agentSkills == null || agentSkills.isEmpty()) {
        result.matched = false;
        return result;
    }
    
    // Check each skill mapping
    for (Routing_Skill_Mapping__mdt mapping : skillMappings) {
        String skillDimension = mapping.Agent_Skill__r.DeveloperName;  // e.g., "Language"
        String workRecordField = mapping.Work_Record_Field__c;  // e.g., "Language__c"
        String operator = mapping.Operator__c;  // "INCLUDES", "EXCLUDES", etc.
        Boolean isRequired = mapping.Is_Required__c;
        
        // Get agent's values for this skill
        Set<String> agentValues = agentSkills.get(skillDimension) ?? new Set<String>();
        
        // Get work record's value
        String workValue = (String) workRecord.get(workRecordField);
        
        // Match based on operator
        Boolean matches = false;
        if (operator == 'INCLUDES') {
            // Agent's skill set includes work record's value
            matches = agentValues.contains(workValue);
        } else if (operator == 'EXCLUDES') {
            matches = !agentValues.contains(workValue);
        }
        
        // If required skill and doesn't match, fail immediately
        if (isRequired && !matches) {
            result.matched = false;
            return result;
        }
    }
    
    result.matched = true;
    return result;
}
```

**Example:**
- Agent John has Language={en_US, fr_CA}
- Case has Language__c="en_US"
- Skill Mapping: Agent_Skill=Language, Work_Record_Field=Language__c, Operator=INCLUDES, Required=true
- **Result:** MATCH ✓

**Governor Cost:** 0 SOQL (uses pre-loaded capability map).

---

### Step 4h: AssignmentResolver.resolve()

**File:** `force-app/main/default/classes/AssignmentResolver.cls`  
**Method:** `resolve()` (lines 120-200)

**Purpose:** Lock the candidate record, update its owner, increment agent load.

```apex
public static AssignmentOutcome resolve(
    SObject candidate,
    Id agentUserId,
    Routing_Config__mdt config,
    Agent__c agent,
    Integer candidateCount
) {
    Id recordId = candidate.Id;
    Integer retryCount = 0;
    Integer maxRetries = (Integer) config.Max_Retry_Attempts__c ?? 3;
    
    // Retry loop: handle lock contention
    while (retryCount < maxRetries) {
        retryCount++;
        
        try {
            // Acquire FOR UPDATE lock on the candidate record
            SObject lockedRecord = [
                SELECT Id, OwnerId
                FROM SObject
                WHERE Id = :recordId
                FOR UPDATE
            ];
            
            // Update owner field to the agent's user ID
            lockedRecord.put(config.Owner_Field_API_Name__c, agentUserId);
            
            // DML 1: Update the record (with USER_MODE for FLS)
            Database.update(lockedRecord, false, AccessLevel.USER_MODE);
            
            // DML 2: Increment agent's load and update Last_Assigned
            agent.Current_Load__c = (agent.Current_Load__c ?? 0) + 1;
            agent.Last_Assigned__c = System.now();
            Database.update(agent, false, AccessLevel.USER_MODE);
            
            // Success!
            return outcomeAssigned(recordId, retryCount, candidateCount);
            
        } catch (QueryException ex) {
            // Lock contention — another agent assigned this record
            if (retryCount >= maxRetries) {
                return outcomeLocked(candidateCount, retryCount);
            }
            // Retry...
        }
    }
    
    return outcomeLocked(candidateCount, maxRetries);
}
```

**What it does:**
1. **Lock** the candidate record (FOR UPDATE)
2. **Update** the owner field to the agent
3. **Increment** agent's Current_Load__c
4. **Update** agent's Last_Assigned__c timestamp
5. **Return** outcome (success or lock contention)

**Retry Logic:** If another agent locked the record first, retry up to 3 times.

**Governor Cost:** 2 SOQL + 2 DML on success, more on lock retry.

---

### Step 4i: AuditLogger.log()

**File:** `force-app/main/default/classes/AuditLogger.cls`  
**Method:** `log()` (lines 20-80)

```apex
public static void log(
    Id recordId,
    String configDevName,
    AssignmentResolver.AssignmentOutcome outcome,
    Boolean dryRun
) {
    if (dryRun) {
        return;  // Don't log in dryRun mode
    }
    
    // Build Routing_Log__c record
    Routing_Log__c auditLog = new Routing_Log__c();
    auditLog.Record_Id__c = String.valueOf(recordId);
    auditLog.Config_Developer_Name__c = configDevName;
    auditLog.Assigned_To__c = outcome.assignedToUserId;
    auditLog.Status__c = outcome.status;  // "Success", "No_Match", "Locked"
    auditLog.Candidate_Count__c = outcome.candidateCount;
    auditLog.Retry_Count__c = outcome.retryCount;
    auditLog.Error_Message__c = outcome.errorMessage;
    auditLog.Routed_At__c = System.now();
    
    // Insert (insert-only table — no updates)
    Database.insert(auditLog, false, AccessLevel.USER_MODE);
}
```

**What it does:**
- Creates a **Routing_Log__c** audit record
- Logs outcome (success/failure), agent, config, timestamp
- Helps admins troubleshoot routing issues

**Governor Cost:** 1 DML (insert).

---

### Step 5: Return to LWC

**Back in RoutingService.getNextRecord()**

```apex
return RoutingResult.success(
    outcome.recordId,
    candidate.get('Name')  // e.g., "Case #12345"
);
```

---

### Step 6: LWC Handles Success

**Back in ureAgentWorkPanel.js**

```javascript
const result = await getNextWork({...});

if (result.success) {
    showToast('Success', 
        `${result.recordName} assigned!`, 
        'success'
    );
    
    // Refresh agent context to show updated load
    this.refreshAgentContext();
    
} else {
    showToast('Error', result.errorMessage, 'error');
}
```

---

## Summary: Complete Call Stack

```
User clicks "Next Best Action"
    ↓ [LWC]
ureAgentWorkPanel.handleGetNextWork()
    ↓ [Apex Entry Point]
RoutingService.getNextRecord()
    ↓ [Apex Dispatcher]
RoutingService.executeSingle()
    ↓ [Apex Orchestrator — 6 Phases]
RoutingEngine.execute()
    │
    ├─ Phase 1: request.validate() — [0 SOQL, 0 DML]
    ├─ Phase 2: AgentCapabilitySelector.getActiveAgentsByUserId() — [1 SOQL]
    ├─ Phase 2: Agent capacity/availability gates — [0 SOQL]
    ├─ Phase 3: ConfigLoader.loadActive() — [0 SOQL, uses CMDT.getAll()]
    ├─ Phase 3: RuleEvaluator.evaluate() — [0 SOQL]
    ├─ Phase 4 (for each applicable config):
    │   ├─ AgentCapabilitySelector.getCapabilityMap() — [2-3 SOQL on first, 0 after]
    │   ├─ AgentMatcher.evaluate() — [0 SOQL]
    │   ├─ DynamicQueryBuilder.build() — [0 SOQL]
    │   ├─ CandidateSelector.query() — [1 SOQL]
    │   ├─ AssignmentResolver.resolve() — [2 DML]
    │   └─ AuditLogger.log() — [1 DML]
    │
    └─ Return RoutingResult
    
    ↓ [Back to LWC]
ureAgentWorkPanel.showToast()
```

---

## Governor Budgets

### Typical Single-Config Execution

| Phase | SOQL | DML | Notes |
|-------|------|-----|-------|
| Phase 1-2 | 1 | 0 | Agent load query |
| Phase 3 | 0 | 0 | CMDT cached |
| Phase 4a | 2-3 | 0 | Agent skills (cached after first) |
| Phase 4c | 1 | 0 | Candidate query |
| Phase 4d | 0 | 2 | Lock + update agent |
| Phase 5 | 0 | 1 | Audit log |
| **TOTAL** | **5-6** | **3** | Per config |

### Multi-Config Execution

If 3 configs are applicable but first 2 fail (no match), third succeeds:
- Phase 4 repeats 3 times
- Cost multiplies by config count
- Most Salesforce orgs can handle 10+ configs before hitting limits

---

## Error Scenarios

### Scenario 1: Agent Not Active

```
Phase 2 Gate → currentAgent == null
    ↓
return RoutingResult.failure(
    "No active Agent record found"
)
    ↓
LWC shows error toast
    ↓
No SOQL after Phase 2 — fail-fast!
```

### Scenario 2: No Candidates Found

```
Phase 4c → CandidateSelector.query() returns []
    ↓
continue to next config
    ↓
If all configs return [], return failure
    ↓
LWC shows "No records available"
```

### Scenario 3: Lock Contention

```
Phase 4d → AssignmentResolver.resolve()
    ↓
FOR UPDATE lock fails (another agent got it)
    ↓
Retry loop executes (max 3 times)
    ↓
If retries exhausted, return outcomeLocked()
    ↓
LWC shows "Record locked, try again"
```

---

**NEXT:** Read Document 3 for step-by-step setup instructions and gaps/issues.
