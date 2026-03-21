// Create 10 dummy Case records
List<Case> cases = new List<Case>();
String[] subjects = new String[]{
    'Billing Inquiry - Account Overcharge',
    'Technical Support - Login Issue',
    'Product Defect - Widget Malfunction',
    'Shipping Delay - Order #10234',
    'Feature Request - Dashboard Export',
    'Password Reset - Locked Account',
    'Refund Request - Duplicate Charge',
    'Installation Help - New Software',
    'Service Outage - Region East',
    'Data Migration - Legacy Import'
};
String[] statuses = new String[]{'New','Working','Escalated','New','Working','New','Escalated','New','Working','New'};
String[] priorities = new String[]{'High','Medium','Low','High','Medium','Low','High','Medium','Low','High'};
String[] origins = new String[]{'Phone','Email','Web','Phone','Email','Web','Phone','Email','Web','Phone'};
String[] types = new String[]{'Problem','Question','Feature Request','Problem','Question','Feature Request','Problem','Question','Feature Request','Problem'};

for (Integer i = 0; i < 10; i++) {
    cases.add(new Case(
        Subject = subjects[i],
        Status = statuses[i],
        Priority = priorities[i],
        Origin = origins[i],
        Type = types[i],
        Description = 'Dummy case #' + (i+1) + ' for routing engine testing.'
    ));
}
insert cases;
System.debug('Inserted ' + cases.size() + ' Case records.');
for (Case c : cases) {
    System.debug('Case: ' + c.Id + ' - ' + c.Subject);
}
