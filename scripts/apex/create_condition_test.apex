// Test single condition with callback-style debug
Metadata.DeployContainer container = new Metadata.DeployContainer();

Metadata.CustomMetadata c1 = new Metadata.CustomMetadata();
c1.fullName = 'ure__Routing_Condition.Case_Status_Open';
c1.label = 'Case Status Open';
c1.values = new List<Metadata.CustomMetadataValue>();

Metadata.CustomMetadataValue v1 = new Metadata.CustomMetadataValue();
v1.field = 'ure__Field_API_Name__c'; v1.value = 'Status';
c1.values.add(v1);

Metadata.CustomMetadataValue v2 = new Metadata.CustomMetadataValue();
v2.field = 'ure__Is_Active__c'; v2.value = true;
c1.values.add(v2);

Metadata.CustomMetadataValue v3 = new Metadata.CustomMetadataValue();
v3.field = 'ure__Is_Indexed__c'; v3.value = true;
c1.values.add(v3);

Metadata.CustomMetadataValue v4 = new Metadata.CustomMetadataValue();
v4.field = 'ure__Operator__c'; v4.value = 'IN';
c1.values.add(v4);

// Try just DeveloperName for the relationship
Metadata.CustomMetadataValue v5 = new Metadata.CustomMetadataValue();
v5.field = 'ure__Routing_Config__c'; v5.value = 'Case_Routing';
c1.values.add(v5);

Metadata.CustomMetadataValue v6 = new Metadata.CustomMetadataValue();
v6.field = 'ure__Sort_Order__c'; v6.value = 1;
c1.values.add(v6);

Metadata.CustomMetadataValue v7 = new Metadata.CustomMetadataValue();
v7.field = 'ure__Values__c'; v7.value = 'New,Working,Escalated';
c1.values.add(v7);

Metadata.CustomMetadataValue v8 = new Metadata.CustomMetadataValue();
v8.field = 'ure__Value_Source__c'; v8.value = 'STATIC';
c1.values.add(v8);

Metadata.CustomMetadataValue v9 = new Metadata.CustomMetadataValue();
v9.field = 'ure__Value_Type__c'; v9.value = 'String';
c1.values.add(v9);

container.addMetadata(c1);

Id jobId = Metadata.Operations.enqueueDeployment(container, null);
System.debug('Test condition deploy Job ID: ' + jobId);
