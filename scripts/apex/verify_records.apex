// Verify all records
System.debug('=== Cases ===');
List<Case> cases = [SELECT Id, Subject, Status, Priority, Origin FROM Case ORDER BY CreatedDate DESC LIMIT 10];
System.debug('Case count: ' + cases.size());
for (Case c : cases) {
    System.debug('  ' + c.Subject + ' | ' + c.Status + ' | ' + c.Priority + ' | ' + c.Origin);
}

System.debug('=== Opportunities ===');
List<Opportunity> opps = [SELECT Id, Name, StageName, Amount, CloseDate FROM Opportunity ORDER BY CreatedDate DESC LIMIT 10];
System.debug('Opp count: ' + opps.size());
for (Opportunity o : opps) {
    System.debug('  ' + o.Name + ' | ' + o.StageName + ' | ' + o.Amount + ' | ' + o.CloseDate);
}

System.debug('=== Routing_Config__mdt ===');
List<ure__Routing_Config__mdt> configs = [SELECT DeveloperName, ure__Object_API_Name__c, ure__Active__c, ure__Priority_Weight__c FROM ure__Routing_Config__mdt];
System.debug('Config count: ' + configs.size());
for (ure__Routing_Config__mdt rc : configs) {
    System.debug('  ' + rc.DeveloperName + ' | ' + rc.ure__Object_API_Name__c + ' | Active=' + rc.ure__Active__c + ' | Weight=' + rc.ure__Priority_Weight__c);
}

System.debug('=== Routing_Condition__mdt ===');
List<ure__Routing_Condition__mdt> conditions = [SELECT DeveloperName, ure__Field_API_Name__c, ure__Operator__c, ure__Values__c FROM ure__Routing_Condition__mdt];
System.debug('Condition count: ' + conditions.size());
for (ure__Routing_Condition__mdt cond : conditions) {
    System.debug('  ' + cond.DeveloperName + ' | ' + cond.ure__Field_API_Name__c + ' ' + cond.ure__Operator__c + ' ' + cond.ure__Values__c);
}

System.debug('=== Routing_Priority__mdt ===');
List<ure__Routing_Priority__mdt> priorities = [SELECT DeveloperName, ure__Sort_Field_API_Name__c, ure__Sort_Direction__c, ure__Sort_Order__c FROM ure__Routing_Priority__mdt];
System.debug('Priority count: ' + priorities.size());
for (ure__Routing_Priority__mdt p : priorities) {
    System.debug('  ' + p.DeveloperName + ' | ' + p.ure__Sort_Field_API_Name__c + ' ' + p.ure__Sort_Direction__c + ' | Order=' + p.ure__Sort_Order__c);
}
