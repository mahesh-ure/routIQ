// Create 10 dummy Opportunity records
List<Opportunity> opps = new List<Opportunity>();
String[] names = new String[]{
    'Acme Corp - Enterprise License',
    'GlobalTech - Platform Upgrade',
    'StartupXYZ - Initial Purchase',
    'MegaCo - Renewal FY2026',
    'DataDriven Inc - Add-On Modules',
    'CloudFirst - Migration Deal',
    'RetailMax - POS Integration',
    'HealthPlus - Compliance Suite',
    'EduLearn - Campus License',
    'FinServe - Risk Analytics'
};
String[] stages = new String[]{
    'Prospecting','Qualification','Needs Analysis','Value Proposition',
    'Id. Decision Makers','Perception Analysis','Proposal/Price Quote',
    'Negotiation/Review','Prospecting','Qualification'
};
Decimal[] amounts = new Decimal[]{50000,120000,15000,85000,30000,200000,45000,175000,60000,95000};

Date baseClose = Date.today().addDays(30);
for (Integer i = 0; i < 10; i++) {
    opps.add(new Opportunity(
        Name = names[i],
        StageName = stages[i],
        CloseDate = baseClose.addDays(i * 7),
        Amount = amounts[i],
        Description = 'Dummy opportunity #' + (i+1) + ' for routing engine testing.'
    ));
}
insert opps;
System.debug('Inserted ' + opps.size() + ' Opportunity records.');
for (Opportunity o : opps) {
    System.debug('Opp: ' + o.Id + ' - ' + o.Name);
}
