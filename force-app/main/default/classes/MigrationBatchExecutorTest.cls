@IsTest
private class MigrationBatchExecutorTest {

    @IsTest
    static void execute_insertPath_loadsRecordsAndWritesLogs() {
        MigrationJob__c job = MigrationTestDataFactory.createJob(false);
        update new MigrationJob__c(Id = job.Id, Status__c = 'InProgress',
            TotalRecords__c = 1, LoadedCount__c = 0, FailedCount__c = 0);
        MigrationObjectConfig__c cfg = MigrationTestDataFactory.createConfig(job.Id, 'Account', 1);
        MigrationTestDataFactory.createMapping(cfg.Id, 'Name', 'Name', false, null);

        String payload = JSON.serialize(new List<Map<String,Object>>{
            new Map<String,Object>{ 'Id' => 'LEGACY-001', 'Name' => 'Test Account' }
        });
        MigrationTestDataFactory.createBatch(job.Id, cfg.Id, 1, payload, 'Pending');

        Test.startTest();
        System.enqueueJob(new MigrationBatchExecutor(job.Id, 1));
        Test.stopTest();

        List<MigrationRecordLog__c> logs = [
            SELECT SalesforceId__c, LegacyId__c FROM MigrationRecordLog__c
            WHERE MigrationJob__c = :job.Id];
        System.assertEquals(1, logs.size(), 'One log record per successful insert');
        System.assertEquals('LEGACY-001', logs[0].LegacyId__c);
        System.assertNotEquals(null, logs[0].SalesforceId__c);
    }

    @IsTest
    static void execute_noBatchFound_finalizesJob() {
        MigrationJob__c job = MigrationTestDataFactory.createJob(false);
        update new MigrationJob__c(Id = job.Id, Status__c = 'InProgress',
            TotalRecords__c = 0, LoadedCount__c = 0, FailedCount__c = 0,
            LastCompletedBatchSequence__c = null);

        Test.startTest();
        System.enqueueJob(new MigrationBatchExecutor(job.Id, 1));
        Test.stopTest();

        String status = [SELECT Status__c FROM MigrationJob__c WHERE Id = :job.Id].Status__c;
        System.assertEquals('Completed', status, 'Job with no batches should complete immediately');
    }

    @IsTest
    static void execute_cancelledJob_doesNotProcess() {
        MigrationJob__c job = MigrationTestDataFactory.createJob(false);
        update new MigrationJob__c(Id = job.Id, Status__c = 'Cancelled');

        Test.startTest();
        System.enqueueJob(new MigrationBatchExecutor(job.Id, 1));
        Test.stopTest();

        // No logs should be written for a cancelled job
        Integer logCount = [SELECT COUNT() FROM MigrationRecordLog__c WHERE MigrationJob__c = :job.Id];
        System.assertEquals(0, logCount, 'Cancelled job should not write logs');
    }

    @IsTest
    static void execute_checkpointResume_skipsCompletedBatches() {
        MigrationJob__c job = MigrationTestDataFactory.createJob(false);
        update new MigrationJob__c(Id = job.Id, Status__c = 'InProgress',
            TotalRecords__c = 2, LoadedCount__c = 1, LastCompletedBatchSequence__c = 1);
        MigrationObjectConfig__c cfg = MigrationTestDataFactory.createConfig(job.Id, 'Account', 1);

        // Batch 1 already completed, batch 2 is pending
        MigrationTestDataFactory.createBatch(job.Id, cfg.Id, 1, '[]', 'Completed');
        MigrationTestDataFactory.createMapping(cfg.Id, 'Name', 'Name', false, null);
        String payload = JSON.serialize(new List<Map<String,Object>>{
            new Map<String,Object>{ 'Id' => 'L002', 'Name' => 'Resume Account' }
        });
        MigrationTestDataFactory.createBatch(job.Id, cfg.Id, 2, payload, 'Pending');

        Test.startTest();
        System.enqueueJob(new MigrationBatchExecutor(job.Id, 1));
        Test.stopTest();

        // Should have processed batch 2 and written 1 log
        Integer logCount = [SELECT COUNT() FROM MigrationRecordLog__c WHERE MigrationJob__c = :job.Id];
        System.assertEquals(1, logCount, 'Checkpoint resume should process only unprocessed batch');
    }
}
