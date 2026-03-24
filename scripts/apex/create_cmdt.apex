// Deploy Routing_Config__mdt records using Metadata.Operations
Metadata.DeployContainer container = new Metadata.DeployContainer();

// ============================================================
// 1. Case Routing Config
// ============================================================
Metadata.CustomMetadata caseConfig = new Metadata.CustomMetadata();
caseConfig.fullName = 'ure__Routing_Config.Case_Routing';
caseConfig.label = 'Case Routing';
caseConfig.values = new List<Metadata.CustomMetadataValue>();

Metadata.CustomMetadataValue v1 = new Metadata.CustomMetadataValue();
v1.field = 'ure__Active__c'; v1.value = true;
caseConfig.values.add(v1);

Metadata.CustomMetadataValue v2 = new Metadata.CustomMetadataValue();
v2.field = 'ure__Allow_Multiple__c'; v2.value = true;
caseConfig.values.add(v2);

Metadata.CustomMetadataValue v3 = new Metadata.CustomMetadataValue();
v3.field = 'ure__Candidate_Limit__c'; v3.value = 50;
caseConfig.values.add(v3);

Metadata.CustomMetadataValue v4 = new Metadata.CustomMetadataValue();
v4.field = 'ure__Closed_Status_Values__c'; v4.value = 'Closed,Resolved,Cancelled';
caseConfig.values.add(v4);

Metadata.CustomMetadataValue v5 = new Metadata.CustomMetadataValue();
v5.field = 'ure__Object_API_Name__c'; v5.value = 'Case';
caseConfig.values.add(v5);

Metadata.CustomMetadataValue v6 = new Metadata.CustomMetadataValue();
v6.field = 'ure__Owner_Field_API_Name__c'; v6.value = 'OwnerId';
caseConfig.values.add(v6);

Metadata.CustomMetadataValue v7 = new Metadata.CustomMetadataValue();
v7.field = 'ure__Pre_Assignment_Owner_Type__c'; v7.value = 'Queue';
caseConfig.values.add(v7);

Metadata.CustomMetadataValue v8 = new Metadata.CustomMetadataValue();
v8.field = 'ure__Priority_Weight__c'; v8.value = 10;
caseConfig.values.add(v8);

Metadata.CustomMetadataValue v9 = new Metadata.CustomMetadataValue();
v9.field = 'ure__Select_Fields__c'; v9.value = 'Subject,Priority,Status,Origin,Type';
caseConfig.values.add(v9);

container.addMetadata(caseConfig);

// ============================================================
// 2. Opportunity Routing Config
// ============================================================
Metadata.CustomMetadata oppConfig = new Metadata.CustomMetadata();
oppConfig.fullName = 'ure__Routing_Config.Opportunity_Routing';
oppConfig.label = 'Opportunity Routing';
oppConfig.values = new List<Metadata.CustomMetadataValue>();

Metadata.CustomMetadataValue o1 = new Metadata.CustomMetadataValue();
o1.field = 'ure__Active__c'; o1.value = true;
oppConfig.values.add(o1);

Metadata.CustomMetadataValue o2 = new Metadata.CustomMetadataValue();
o2.field = 'ure__Allow_Multiple__c'; o2.value = false;
oppConfig.values.add(o2);

Metadata.CustomMetadataValue o3 = new Metadata.CustomMetadataValue();
o3.field = 'ure__Candidate_Limit__c'; o3.value = 25;
oppConfig.values.add(o3);

Metadata.CustomMetadataValue o4 = new Metadata.CustomMetadataValue();
o4.field = 'ure__Closed_Status_Values__c'; o4.value = 'Closed Won,Closed Lost';
oppConfig.values.add(o4);

Metadata.CustomMetadataValue o5 = new Metadata.CustomMetadataValue();
o5.field = 'ure__Object_API_Name__c'; o5.value = 'Opportunity';
oppConfig.values.add(o5);

Metadata.CustomMetadataValue o6 = new Metadata.CustomMetadataValue();
o6.field = 'ure__Owner_Field_API_Name__c'; o6.value = 'OwnerId';
oppConfig.values.add(o6);

Metadata.CustomMetadataValue o7 = new Metadata.CustomMetadataValue();
o7.field = 'ure__Priority_Weight__c'; o7.value = 20;
oppConfig.values.add(o7);

Metadata.CustomMetadataValue o8 = new Metadata.CustomMetadataValue();
o8.field = 'ure__Select_Fields__c'; o8.value = 'Name,StageName,Amount,CloseDate';
oppConfig.values.add(o8);

container.addMetadata(oppConfig);

// Enqueue deployment
Id jobId = Metadata.Operations.enqueueDeployment(container, null);
System.debug('Routing_Config deployment enqueued. Job ID: ' + jobId);
