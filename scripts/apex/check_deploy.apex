// Check deployment statuses
List<DeployRequest> deploys = [SELECT Id, Status, StartDate, CompletedDate, ErrorMessage
                                FROM DeployRequest
                                WHERE CreatedDate = TODAY
                                ORDER BY CreatedDate DESC LIMIT 5];
for (DeployRequest dr : deploys) {
    System.debug('Deploy ' + dr.Id + ' | Status=' + dr.Status + ' | Error=' + dr.ErrorMessage);
}
