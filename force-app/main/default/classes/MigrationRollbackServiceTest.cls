@IsTest
private class MigrationRollbackServiceTest {

    @IsTest
    static void startRollback_pendingStatus_startsSuccessfully() {
        MigrationJob__c job = MigrationTestDataFactory.createJob(false);
        update new MigrationJob__c(Id = job.Id, Status__c = 'Completed', LoadedCount__c = 0);
        MigrationRollback__c rb = MigrationTestDataFactory.createRollback(job.Id, 'Pending');

        Test.startTest();
        MigrationRollbackService.startRollback(rb.Id);
        Test.stopTest();

        MigrationRollback__c updated = [SELECT Status__c FROM MigrationRollback__c WHERE Id = :rb.Id];
        System.assertNotEquals('Pending', updated.Status__c, 'Status should advance past Pending');
    }

    @IsTest
    static void startRollback_nonPendingStatus_throwsException() {
        MigrationJob__c job = MigrationTestDataFactory.createJob(false);
        MigrationRollback__c rb = MigrationTestDataFactory.createRollback(job.Id, 'InProgress');

        Test.startTest();
        try {
            MigrationRollbackService.startRollback(rb.Id);
            System.assert(false, 'Should have thrown MigrationException');
        } catch (MigrationException ex) {
            System.assert(ex.getMessage().contains('Pending'));
        }
        Test.stopTest();
    }

    @IsTest
    static void rollback_deletesLoggedRecords() {
        MigrationJob__c job = MigrationTestDataFactory.createJob(false);
        update new MigrationJob__c(Id = job.Id, Status__c = 'Completed', LoadedCount__c = 0);
        MigrationObjectConfig__c cfg = MigrationTestDataFactory.createConfig(job.Id, 'Account', 1);
        MigrationBatch__c batch = MigrationTestDataFactory.createBatch(job.Id, cfg.Id, 1, '[]', 'Completed');

        // Create a real Account so the delete can succeed
        Account acct = new Account(Name = 'Rollback Test');
        insert acct;
        insert new MigrationRecordLog__c(
            MigrationJob__c   = job.Id,
            MigrationBatch__c = batch.Id,
            LegacyId__c       = 'legacy-001',
            SalesforceId__c   = acct.Id,
            ObjectApiName__c  = 'Account',
            LoadOrder__c      = 1
        );

        MigrationRollback__c rb = MigrationTestDataFactory.createRollback(job.Id, 'Pending');

        Test.startTest();
        MigrationRollbackService.startRollback(rb.Id);
        Test.stopTest();

        List<Account> remaining = [SELECT Id FROM Account WHERE Id = :acct.Id];
        System.assertEquals(0, remaining.size(), 'Rollback should have deleted the Account');
    }
}
