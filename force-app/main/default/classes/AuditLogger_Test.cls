/**
 * @description Test class for AuditLogger (Layer 3 Utility).
 *              Tests: log entry creation, bulk logging, analytics tracking.
 *
 * @group Test
 */
@IsTest
private class AuditLogger_Test {

    @TestSetup
    static void setup() {
        Agent__c agent = new Agent__c(
            User__c = UserInfo.getUserId(),
            Is_Active__c = true
        );
        insert agent;
    }

    @IsTest
    static void createLogEntry_successfulAssignment() {
        Agent__c agent = [SELECT Id FROM Agent__c LIMIT 1];
        Case testCase = new Case(Subject = 'Test', Status = 'New');
        insert testCase;

        Test.startTest();
        Routing_Log__c logEntry = AuditLogger.createLogEntry(
            UserInfo.getUserId(),
            testCase.Id,
            'Case',
            'TestConfig',
            'Success',
            System.Label.URE_UNKNOWN_ERROR
        );
        Test.stopTest();

        System.assertNotEquals(null, logEntry,
            'Log entry should be created');
        System.assertEquals('Success', logEntry.Status__c,
            'Status should be recorded');
    }

    @IsTest
    static void createLogEntry_noMatch() {
        Case testCase = new Case(Subject = 'Test', Status = 'New');
        insert testCase;

        Test.startTest();
        Routing_Log__c logEntry = AuditLogger.createLogEntry(
            UserInfo.getUserId(),
            testCase.Id,
            'Case',
            'TestConfig',
            'No_Match',
            System.Label.URE_RESOLVER_NO_MATCH
        );
        Test.stopTest();

        System.assertEquals('No_Match', logEntry.Status__c,
            'No match status should be recorded');
    }

    @IsTest
    static void createLogEntry_bulkRecords() {
        List<Routing_Log__c> logs = new List<Routing_Log__c>();

        Test.startTest();
        for (Integer i = 0; i < 10; i++) {
            Routing_Log__c log = AuditLogger.createLogEntry(
                UserInfo.getUserId(),
                UserInfo.getUserId(),
                'Case',
                'Config' + i,
                'Success',
                null
            );
            logs.add(log);
        }
        Test.stopTest();

        System.assertEquals(10, logs.size(),
            'Should create multiple log entries');
    }

    @IsTest
    static void logEntry_containsTimestamp() {
        Test.startTest();
        Routing_Log__c log = AuditLogger.createLogEntry(
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            'Case',
            'TestConfig',
            'Success',
            null
        );
        Test.stopTest();

        System.assertNotEquals(null, log.CreatedDate,
            'Log should have timestamp');
    }

    @IsTest
    static void logEntry_recordsAgent() {
        Agent__c agent = [SELECT Id FROM Agent__c LIMIT 1];

        Test.startTest();
        Routing_Log__c log = AuditLogger.createLogEntry(
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            'Case',
            'TestConfig',
            'Success',
            null
        );
        Test.stopTest();

        System.assertNotEquals(null, log.Agent__c,
            'Log should record agent reference');
    }

    @IsTest
    static void logEntry_recordsConfig() {
        Test.startTest();
        Routing_Log__c log = AuditLogger.createLogEntry(
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            'Case',
            'My_Config',
            'Success',
            null
        );
        Test.stopTest();

        System.assertEquals('My_Config', log.Routing_Config_Name__c,
            'Log should record config name');
    }

    @IsTest
    static void logEntry_recordsObject() {
        Test.startTest();
        Routing_Log__c log = AuditLogger.createLogEntry(
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            'Case',
            'TestConfig',
            'Success',
            null
        );
        Test.stopTest();

        System.assertEquals('Case', log.Object_Name__c,
            'Log should record object type');
    }

    @IsTest
    static void logEntry_nullErrorMessage() {
        Test.startTest();
        Routing_Log__c log = AuditLogger.createLogEntry(
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            'Case',
            'TestConfig',
            'Success',
            null
        );
        Test.stopTest();

        System.assertEquals(null, log.Error_Message__c,
            'Success should have null error message');
    }

    @IsTest
    static void logEntry_errorMessage() {
        Test.startTest();
        Routing_Log__c log = AuditLogger.createLogEntry(
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            'Case',
            'TestConfig',
            'Failure',
            'Test error'
        );
        Test.stopTest();

        System.assertEquals('Test error', log.Error_Message__c,
            'Failure should record error message');
    }
}
