// Deploy all Routing_Condition__mdt records (using DeveloperName for relationship)
Metadata.DeployContainer container = new Metadata.DeployContainer();

// Helper-style inline approach
// 1. Case Status Open - already deployed, skip

// 2. Case Priority High
Metadata.CustomMetadata c2 = new Metadata.CustomMetadata();
c2.fullName = 'ure__Routing_Condition.Case_Priority_High';
c2.label = 'Case Priority High';
c2.values = new List<Metadata.CustomMetadataValue>();
Metadata.CustomMetadataValue c2v1 = new Metadata.CustomMetadataValue(); c2v1.field = 'ure__Field_API_Name__c'; c2v1.value = 'Priority'; c2.values.add(c2v1);
Metadata.CustomMetadataValue c2v2 = new Metadata.CustomMetadataValue(); c2v2.field = 'ure__Is_Active__c'; c2v2.value = true; c2.values.add(c2v2);
Metadata.CustomMetadataValue c2v3 = new Metadata.CustomMetadataValue(); c2v3.field = 'ure__Is_Indexed__c'; c2v3.value = false; c2.values.add(c2v3);
Metadata.CustomMetadataValue c2v4 = new Metadata.CustomMetadataValue(); c2v4.field = 'ure__Operator__c'; c2v4.value = 'IN'; c2.values.add(c2v4);
Metadata.CustomMetadataValue c2v5 = new Metadata.CustomMetadataValue(); c2v5.field = 'ure__Routing_Config__c'; c2v5.value = 'Case_Routing'; c2.values.add(c2v5);
Metadata.CustomMetadataValue c2v6 = new Metadata.CustomMetadataValue(); c2v6.field = 'ure__Sort_Order__c'; c2v6.value = 2; c2.values.add(c2v6);
Metadata.CustomMetadataValue c2v7 = new Metadata.CustomMetadataValue(); c2v7.field = 'ure__Values__c'; c2v7.value = 'High,Medium'; c2.values.add(c2v7);
Metadata.CustomMetadataValue c2v8 = new Metadata.CustomMetadataValue(); c2v8.field = 'ure__Value_Source__c'; c2v8.value = 'STATIC'; c2.values.add(c2v8);
Metadata.CustomMetadataValue c2v9 = new Metadata.CustomMetadataValue(); c2v9.field = 'ure__Value_Type__c'; c2v9.value = 'String'; c2.values.add(c2v9);
container.addMetadata(c2);

// 3. Case Origin Filter
Metadata.CustomMetadata c3 = new Metadata.CustomMetadata();
c3.fullName = 'ure__Routing_Condition.Case_Origin_Filter';
c3.label = 'Case Origin Filter';
c3.values = new List<Metadata.CustomMetadataValue>();
Metadata.CustomMetadataValue c3v1 = new Metadata.CustomMetadataValue(); c3v1.field = 'ure__Field_API_Name__c'; c3v1.value = 'Origin'; c3.values.add(c3v1);
Metadata.CustomMetadataValue c3v2 = new Metadata.CustomMetadataValue(); c3v2.field = 'ure__Is_Active__c'; c3v2.value = true; c3.values.add(c3v2);
Metadata.CustomMetadataValue c3v3 = new Metadata.CustomMetadataValue(); c3v3.field = 'ure__Is_Indexed__c'; c3v3.value = false; c3.values.add(c3v3);
Metadata.CustomMetadataValue c3v4 = new Metadata.CustomMetadataValue(); c3v4.field = 'ure__Operator__c'; c3v4.value = 'IN'; c3.values.add(c3v4);
Metadata.CustomMetadataValue c3v5 = new Metadata.CustomMetadataValue(); c3v5.field = 'ure__Routing_Config__c'; c3v5.value = 'Case_Routing'; c3.values.add(c3v5);
Metadata.CustomMetadataValue c3v6 = new Metadata.CustomMetadataValue(); c3v6.field = 'ure__Sort_Order__c'; c3v6.value = 3; c3.values.add(c3v6);
Metadata.CustomMetadataValue c3v7 = new Metadata.CustomMetadataValue(); c3v7.field = 'ure__Values__c'; c3v7.value = 'Phone,Email,Web'; c3.values.add(c3v7);
Metadata.CustomMetadataValue c3v8 = new Metadata.CustomMetadataValue(); c3v8.field = 'ure__Value_Source__c'; c3v8.value = 'STATIC'; c3.values.add(c3v8);
Metadata.CustomMetadataValue c3v9 = new Metadata.CustomMetadataValue(); c3v9.field = 'ure__Value_Type__c'; c3v9.value = 'String'; c3.values.add(c3v9);
container.addMetadata(c3);

// 4. Opp Stage Open
Metadata.CustomMetadata c4 = new Metadata.CustomMetadata();
c4.fullName = 'ure__Routing_Condition.Opp_Stage_Open';
c4.label = 'Opp Stage Open';
c4.values = new List<Metadata.CustomMetadataValue>();
Metadata.CustomMetadataValue c4v1 = new Metadata.CustomMetadataValue(); c4v1.field = 'ure__Field_API_Name__c'; c4v1.value = 'StageName'; c4.values.add(c4v1);
Metadata.CustomMetadataValue c4v2 = new Metadata.CustomMetadataValue(); c4v2.field = 'ure__Is_Active__c'; c4v2.value = true; c4.values.add(c4v2);
Metadata.CustomMetadataValue c4v3 = new Metadata.CustomMetadataValue(); c4v3.field = 'ure__Is_Indexed__c'; c4v3.value = true; c4.values.add(c4v3);
Metadata.CustomMetadataValue c4v4 = new Metadata.CustomMetadataValue(); c4v4.field = 'ure__Operator__c'; c4v4.value = 'NOT IN'; c4.values.add(c4v4);
Metadata.CustomMetadataValue c4v5 = new Metadata.CustomMetadataValue(); c4v5.field = 'ure__Routing_Config__c'; c4v5.value = 'Opportunity_Routing'; c4.values.add(c4v5);
Metadata.CustomMetadataValue c4v6 = new Metadata.CustomMetadataValue(); c4v6.field = 'ure__Sort_Order__c'; c4v6.value = 1; c4.values.add(c4v6);
Metadata.CustomMetadataValue c4v7 = new Metadata.CustomMetadataValue(); c4v7.field = 'ure__Values__c'; c4v7.value = 'Closed Won,Closed Lost'; c4.values.add(c4v7);
Metadata.CustomMetadataValue c4v8 = new Metadata.CustomMetadataValue(); c4v8.field = 'ure__Value_Source__c'; c4v8.value = 'STATIC'; c4.values.add(c4v8);
Metadata.CustomMetadataValue c4v9 = new Metadata.CustomMetadataValue(); c4v9.field = 'ure__Value_Type__c'; c4v9.value = 'String'; c4.values.add(c4v9);
container.addMetadata(c4);

// 5. Opp Amount Threshold
Metadata.CustomMetadata c5 = new Metadata.CustomMetadata();
c5.fullName = 'ure__Routing_Condition.Opp_Amount_Threshold';
c5.label = 'Opp Amount Threshold';
c5.values = new List<Metadata.CustomMetadataValue>();
Metadata.CustomMetadataValue c5v1 = new Metadata.CustomMetadataValue(); c5v1.field = 'ure__Field_API_Name__c'; c5v1.value = 'Amount'; c5.values.add(c5v1);
Metadata.CustomMetadataValue c5v2 = new Metadata.CustomMetadataValue(); c5v2.field = 'ure__Is_Active__c'; c5v2.value = true; c5.values.add(c5v2);
Metadata.CustomMetadataValue c5v3 = new Metadata.CustomMetadataValue(); c5v3.field = 'ure__Is_Indexed__c'; c5v3.value = false; c5.values.add(c5v3);
Metadata.CustomMetadataValue c5v4 = new Metadata.CustomMetadataValue(); c5v4.field = 'ure__Operator__c'; c5v4.value = '>='; c5.values.add(c5v4);
Metadata.CustomMetadataValue c5v5 = new Metadata.CustomMetadataValue(); c5v5.field = 'ure__Routing_Config__c'; c5v5.value = 'Opportunity_Routing'; c5.values.add(c5v5);
Metadata.CustomMetadataValue c5v6 = new Metadata.CustomMetadataValue(); c5v6.field = 'ure__Sort_Order__c'; c5v6.value = 2; c5.values.add(c5v6);
Metadata.CustomMetadataValue c5v7 = new Metadata.CustomMetadataValue(); c5v7.field = 'ure__Values__c'; c5v7.value = '10000'; c5.values.add(c5v7);
Metadata.CustomMetadataValue c5v8 = new Metadata.CustomMetadataValue(); c5v8.field = 'ure__Value_Source__c'; c5v8.value = 'STATIC'; c5.values.add(c5v8);
Metadata.CustomMetadataValue c5v9 = new Metadata.CustomMetadataValue(); c5v9.field = 'ure__Value_Type__c'; c5v9.value = 'Number'; c5.values.add(c5v9);
container.addMetadata(c5);

// 6. Opp CloseDate Upcoming
Metadata.CustomMetadata c6 = new Metadata.CustomMetadata();
c6.fullName = 'ure__Routing_Condition.Opp_CloseDate_Upcoming';
c6.label = 'Opp CloseDate Upcoming';
c6.values = new List<Metadata.CustomMetadataValue>();
Metadata.CustomMetadataValue c6v1 = new Metadata.CustomMetadataValue(); c6v1.field = 'ure__Field_API_Name__c'; c6v1.value = 'CloseDate'; c6.values.add(c6v1);
Metadata.CustomMetadataValue c6v2 = new Metadata.CustomMetadataValue(); c6v2.field = 'ure__Is_Active__c'; c6v2.value = true; c6.values.add(c6v2);
Metadata.CustomMetadataValue c6v3 = new Metadata.CustomMetadataValue(); c6v3.field = 'ure__Is_Indexed__c'; c6v3.value = true; c6.values.add(c6v3);
Metadata.CustomMetadataValue c6v4 = new Metadata.CustomMetadataValue(); c6v4.field = 'ure__Operator__c'; c6v4.value = '<='; c6.values.add(c6v4);
Metadata.CustomMetadataValue c6v5 = new Metadata.CustomMetadataValue(); c6v5.field = 'ure__Routing_Config__c'; c6v5.value = 'Opportunity_Routing'; c6.values.add(c6v5);
Metadata.CustomMetadataValue c6v6 = new Metadata.CustomMetadataValue(); c6v6.field = 'ure__Sort_Order__c'; c6v6.value = 3; c6.values.add(c6v6);
Metadata.CustomMetadataValue c6v7 = new Metadata.CustomMetadataValue(); c6v7.field = 'ure__Values__c'; c6v7.value = '2026-06-30'; c6.values.add(c6v7);
Metadata.CustomMetadataValue c6v8 = new Metadata.CustomMetadataValue(); c6v8.field = 'ure__Value_Source__c'; c6v8.value = 'STATIC'; c6.values.add(c6v8);
Metadata.CustomMetadataValue c6v9 = new Metadata.CustomMetadataValue(); c6v9.field = 'ure__Value_Type__c'; c6v9.value = 'Date'; c6.values.add(c6v9);
container.addMetadata(c6);

Id jobId = Metadata.Operations.enqueueDeployment(container, null);
System.debug('All remaining conditions deployed. Job ID: ' + jobId);
