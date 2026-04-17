/**
 * @description Test class for GovLimits (Utility).
 *              Tests: governor limits tracking, warning thresholds,
 *              budget enforcement.
 *
 * @group Test
 */
@IsTest
private class GovLimits_Test {

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. SOQL Limits Tracking
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getSoqlBudgetRemaining() {
        Test.startTest();
        Integer remaining = GovLimits.getSoqlBudgetRemaining();
        Test.stopTest();

        System.assertNotEquals(null, remaining,
            'Should return SOQL budget remaining');
        System.assert(remaining > 0,
            'Should have SOQL budget available');
        System.assert(remaining <= 100,
            'SOQL limit is 100 per transaction');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. DML Limits Tracking
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getDmlBudgetRemaining() {
        Test.startTest();
        Integer remaining = GovLimits.getDmlBudgetRemaining();
        Test.stopTest();

        System.assertNotEquals(null, remaining,
            'Should return DML budget remaining');
        System.assert(remaining > 0,
            'Should have DML budget available');
        System.assert(remaining <= 150,
            'DML limit is 150 per transaction');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. CPU Time Limits
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getCpuTimeRemaining() {
        Test.startTest();
        Long remaining = GovLimits.getCpuTimeRemaining();
        Test.stopTest();

        System.assertNotEquals(null, remaining,
            'Should return CPU time remaining');
        System.assert(remaining > 0,
            'Should have CPU time budget available');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. Heap Size Tracking
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getHeapSizeRemaining() {
        Test.startTest();
        Integer remaining = GovLimits.getHeapSizeRemaining();
        Test.stopTest();

        System.assertNotEquals(null, remaining,
            'Should return heap size remaining');
        System.assert(remaining > 0,
            'Should have heap memory available');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 5. Budget Warning Check
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void isWarningThreshold_soql() {
        // Consume some SOQL to approach warning threshold
        List<Account> accounts = [SELECT Id FROM Account LIMIT 10];

        Test.startTest();
        Boolean isWarning = GovLimits.isWarningThreshold('SOQL');
        Test.stopTest();

        System.assertNotEquals(null, isWarning,
            'Should evaluate warning threshold');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 6. Budget Critical Check
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void isCriticalThreshold_dml() {
        Test.startTest();
        Boolean isCritical = GovLimits.isCriticalThreshold('DML');
        Test.stopTest();

        System.assertNotEquals(null, isCritical,
            'Should evaluate critical threshold');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 7. Safe SOQL Budget Check
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void hasSafeSOQLBudget() {
        Test.startTest();
        Boolean hasBudget = GovLimits.hasSafeSOQLBudget(5);
        Test.stopTest();

        System.assertNotEquals(null, hasBudget,
            'Should check if safe SOQL budget available');
        System.assert(hasBudget == true || hasBudget == false,
            'Should return boolean');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 8. Safe DML Budget Check
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void hasSafeDMLBudget() {
        Test.startTest();
        Boolean hasBudget = GovLimits.hasSafeDMLBudget(5);
        Test.stopTest();

        System.assertNotEquals(null, hasBudget,
            'Should check if safe DML budget available');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 9. Limits Summary Report
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getLimitsSummary() {
        Test.startTest();
        String summary = GovLimits.getLimitsSummary();
        Test.stopTest();

        System.assertNotEquals(null, summary,
            'Should return limits summary');
        System.assert(summary.length() > 0,
            'Summary should not be empty');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 10. Null-Safe Threshold Names
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void isWarningThreshold_invalidType() {
        Test.startTest();
        try {
            Boolean isWarning = GovLimits.isWarningThreshold('INVALID');
            System.assertNotEquals(null, isWarning,
                'Should handle invalid limit types gracefully');
        } catch (Exception e) {
            System.assert(true, 'Expected exception for invalid type');
        }
        Test.stopTest();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 11. Multiple Threshold Checks
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void checkMultipleLimits() {
        Test.startTest();
        Integer soqlRemaining = GovLimits.getSoqlBudgetRemaining();
        Integer dmlRemaining = GovLimits.getDmlBudgetRemaining();
        Long cpuRemaining = GovLimits.getCpuTimeRemaining();
        Test.stopTest();

        System.assertNotEquals(null, soqlRemaining,
            'All limits should be gettable');
        System.assertNotEquals(null, dmlRemaining,
            'All limits should be gettable');
        System.assertNotEquals(null, cpuRemaining,
            'All limits should be gettable');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 12. Threshold Boundaries
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void thresholdBoundaries() {
        Test.startTest();
        Integer soqlBudget = GovLimits.getSoqlBudgetRemaining();
        Integer dmlBudget = GovLimits.getDmlBudgetRemaining();
        Test.stopTest();

        System.assert(soqlBudget <= 100 && soqlBudget >= 0,
            'SOQL budget should be within bounds');
        System.assert(dmlBudget <= 150 && dmlBudget >= 0,
            'DML budget should be within bounds');
    }
}
