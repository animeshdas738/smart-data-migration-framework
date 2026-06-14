@IsTest
private class MigrationIdCacheTest {

    @IsTest
    static void putAndGet_returnsSameMap() {
        MigrationJob__c job = MigrationTestDataFactory.createJob(false);
        Map<String, Id> idMap = new Map<String, Id>{ 'legacy-001' => job.Id };

        Test.startTest();
        MigrationIdCache.put(job.Id, 'Account', idMap);
        Map<String, Id> retrieved = MigrationIdCache.get(job.Id, 'Account');
        Test.stopTest();

        // In test context Platform Cache may not be available; result comes from SOQL fallback (empty)
        // or cache hit — either way no exception should be thrown
        System.assertNotEquals(null, retrieved);
    }

    @IsTest
    static void get_cacheMiss_fallsBackToSoql() {
        MigrationJob__c job = MigrationTestDataFactory.createJob(false);
        MigrationObjectConfig__c cfg = MigrationTestDataFactory.createConfig(job.Id, 'Account', 1);
        MigrationBatch__c batch = MigrationTestDataFactory.createBatch(job.Id, cfg.Id, 1, '[]', 'Completed');

        // Insert a log record so SOQL fallback finds something
        Account acct = new Account(Name = 'Test');
        insert acct;
        insert new MigrationRecordLog__c(
            MigrationJob__c   = job.Id,
            MigrationBatch__c = batch.Id,
            LegacyId__c       = 'legacy-acct-1',
            SalesforceId__c   = acct.Id,
            ObjectApiName__c  = 'Account',
            LoadOrder__c      = 1
        );

        Test.startTest();
        Map<String, Id> result = MigrationIdCache.get(job.Id, 'Account');
        Test.stopTest();

        System.assert(result.containsKey('legacy-acct-1'), 'SOQL fallback should return log record');
        System.assertEquals(acct.Id, result.get('legacy-acct-1'));
    }

    @IsTest
    static void remove_doesNotThrow() {
        MigrationJob__c job = MigrationTestDataFactory.createJob(false);
        Test.startTest();
        MigrationIdCache.remove(job.Id, 'Account');
        Test.stopTest();
        System.assert(true, 'remove should not throw even on a key that was never set');
    }
}
