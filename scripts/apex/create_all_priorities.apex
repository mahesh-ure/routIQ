// Deploy all Routing_Priority__mdt records (using DeveloperName for relationship)
Metadata.DeployContainer container = new Metadata.DeployContainer();

// 1. Case By Priority
Metadata.CustomMetadata p1 = new Metadata.CustomMetadata();
p1.fullName = 'ure__Routing_Priority.Case_By_Priority';
p1.label = 'Case By Priority';
p1.values = new List<Metadata.CustomMetadataValue>();
Metadata.CustomMetadataValue p1v1 = new Metadata.CustomMetadataValue(); p1v1.field = 'ure__Null_Handling__c'; p1v1.value = 'NULLS LAST'; p1.values.add(p1v1);
Metadata.CustomMetadataValue p1v2 = new Metadata.CustomMetadataValue(); p1v2.field = 'ure__Routing_Config__c'; p1v2.value = 'Case_Routing'; p1.values.add(p1v2);
Metadata.CustomMetadataValue p1v3 = new Metadata.CustomMetadataValue(); p1v3.field = 'ure__Sort_Direction__c'; p1v3.value = 'ASC'; p1.values.add(p1v3);
Metadata.CustomMetadataValue p1v4 = new Metadata.CustomMetadataValue(); p1v4.field = 'ure__Sort_Field_API_Name__c'; p1v4.value = 'Priority'; p1.values.add(p1v4);
Metadata.CustomMetadataValue p1v5 = new Metadata.CustomMetadataValue(); p1v5.field = 'ure__Sort_Order__c'; p1v5.value = 1; p1.values.add(p1v5);
container.addMetadata(p1);

// 2. Case By CreatedDate
Metadata.CustomMetadata p2 = new Metadata.CustomMetadata();
p2.fullName = 'ure__Routing_Priority.Case_By_CreatedDate';
p2.label = 'Case By CreatedDate';
p2.values = new List<Metadata.CustomMetadataValue>();
Metadata.CustomMetadataValue p2v1 = new Metadata.CustomMetadataValue(); p2v1.field = 'ure__Null_Handling__c'; p2v1.value = 'NULLS LAST'; p2.values.add(p2v1);
Metadata.CustomMetadataValue p2v2 = new Metadata.CustomMetadataValue(); p2v2.field = 'ure__Routing_Config__c'; p2v2.value = 'Case_Routing'; p2.values.add(p2v2);
Metadata.CustomMetadataValue p2v3 = new Metadata.CustomMetadataValue(); p2v3.field = 'ure__Sort_Direction__c'; p2v3.value = 'ASC'; p2.values.add(p2v3);
Metadata.CustomMetadataValue p2v4 = new Metadata.CustomMetadataValue(); p2v4.field = 'ure__Sort_Field_API_Name__c'; p2v4.value = 'CreatedDate'; p2.values.add(p2v4);
Metadata.CustomMetadataValue p2v5 = new Metadata.CustomMetadataValue(); p2v5.field = 'ure__Sort_Order__c'; p2v5.value = 2; p2.values.add(p2v5);
container.addMetadata(p2);

// 3. Opp By Amount
Metadata.CustomMetadata p3 = new Metadata.CustomMetadata();
p3.fullName = 'ure__Routing_Priority.Opp_By_Amount';
p3.label = 'Opp By Amount';
p3.values = new List<Metadata.CustomMetadataValue>();
Metadata.CustomMetadataValue p3v1 = new Metadata.CustomMetadataValue(); p3v1.field = 'ure__Null_Handling__c'; p3v1.value = 'NULLS LAST'; p3.values.add(p3v1);
Metadata.CustomMetadataValue p3v2 = new Metadata.CustomMetadataValue(); p3v2.field = 'ure__Routing_Config__c'; p3v2.value = 'Opportunity_Routing'; p3.values.add(p3v2);
Metadata.CustomMetadataValue p3v3 = new Metadata.CustomMetadataValue(); p3v3.field = 'ure__Sort_Direction__c'; p3v3.value = 'DESC'; p3.values.add(p3v3);
Metadata.CustomMetadataValue p3v4 = new Metadata.CustomMetadataValue(); p3v4.field = 'ure__Sort_Field_API_Name__c'; p3v4.value = 'Amount'; p3.values.add(p3v4);
Metadata.CustomMetadataValue p3v5 = new Metadata.CustomMetadataValue(); p3v5.field = 'ure__Sort_Order__c'; p3v5.value = 1; p3.values.add(p3v5);
container.addMetadata(p3);

// 4. Opp By CloseDate
Metadata.CustomMetadata p4 = new Metadata.CustomMetadata();
p4.fullName = 'ure__Routing_Priority.Opp_By_CloseDate';
p4.label = 'Opp By CloseDate';
p4.values = new List<Metadata.CustomMetadataValue>();
Metadata.CustomMetadataValue p4v1 = new Metadata.CustomMetadataValue(); p4v1.field = 'ure__Null_Handling__c'; p4v1.value = 'NULLS LAST'; p4.values.add(p4v1);
Metadata.CustomMetadataValue p4v2 = new Metadata.CustomMetadataValue(); p4v2.field = 'ure__Routing_Config__c'; p4v2.value = 'Opportunity_Routing'; p4.values.add(p4v2);
Metadata.CustomMetadataValue p4v3 = new Metadata.CustomMetadataValue(); p4v3.field = 'ure__Sort_Direction__c'; p4v3.value = 'ASC'; p4.values.add(p4v3);
Metadata.CustomMetadataValue p4v4 = new Metadata.CustomMetadataValue(); p4v4.field = 'ure__Sort_Field_API_Name__c'; p4v4.value = 'CloseDate'; p4.values.add(p4v4);
Metadata.CustomMetadataValue p4v5 = new Metadata.CustomMetadataValue(); p4v5.field = 'ure__Sort_Order__c'; p4v5.value = 2; p4.values.add(p4v5);
container.addMetadata(p4);

Id jobId = Metadata.Operations.enqueueDeployment(container, null);
System.debug('All priorities deployed. Job ID: ' + jobId);
