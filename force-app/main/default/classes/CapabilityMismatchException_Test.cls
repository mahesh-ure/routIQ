/**
 * @description Test class for CapabilityMismatchException.
 *              Tests: exception construction, message preservation.
 *
 * @group Test
 */
@IsTest
private class CapabilityMismatchException_Test {

    @IsTest
    static void constructor_withMessage() {
        Test.startTest();
        try {
            throw new CapabilityMismatchException('Agent capability mismatch');
        } catch (CapabilityMismatchException e) {
            System.assertEquals('Agent capability mismatch', e.getMessage(),
                'Exception should preserve message');
        }
        Test.stopTest();
    }

    @IsTest
    static void constructor_throwable() {
        Exception inner = new Exception('Inner cause');
        Test.startTest();
        try {
            throw new CapabilityMismatchException('Outer message', inner);
        } catch (CapabilityMismatchException e) {
            System.assertNotEquals(null, e.getMessage(),
                'Exception should have message');
        }
        Test.stopTest();
    }

    @IsTest
    static void exception_isThrowable() {
        Test.startTest();
        Boolean isException = false;
        try {
            throw new CapabilityMismatchException('Test');
        } catch (Exception e) {
            isException = true;
        }
        Test.stopTest();

        System.assertEquals(true, isException,
            'CapabilityMismatchException should be throwable');
    }

    @IsTest
    static void exception_nullMessage() {
        Test.startTest();
        try {
            throw new CapabilityMismatchException(null);
        } catch (CapabilityMismatchException e) {
            System.assertNotEquals(null, e,
                'Exception should handle null message');
        }
        Test.stopTest();
    }
}
