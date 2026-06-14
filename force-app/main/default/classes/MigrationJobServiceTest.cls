@IsTest
private class MigrationJobServiceTest {

    @IsTest
    static void createJob_returnsDraftId() {
        Test.startTest();
        Id jobId = MigrationJobService.createJob('Test Migration', false);
        Test.stopTest();

        MigrationJob__c job = [SELECT Status__c, IsDryRun__c, JobName__c FROM MigrationJob__c WHERE Id = :jobId];
        System.assertEquals('Draft',            job.Status__c);
        System.assertEquals(false,              job.IsDryRun__c);
        System.assertEquals('Test Migration',   job.JobName__c);
    }

    @IsTest
    static void createDryRunJob_flaggedCorrectly() {
        Test.startTest();
        Id jobId = MigrationJobService.createJob('Dry Run', true);
        Test.stopTest();

        System.assertEquals(true, [SELECT IsDryRun__c FROM MigrationJob__c WHERE Id = :jobId].IsDryRun__c);
    }

    @IsTest
    static void addObjectConfig_insertsRecord() {
        Id jobId = MigrationJobService.createJob('J', false);
        Test.startTest();
        Id configId = MigrationJobService.addObjectConfig(jobId, 'Account', 1, null);
        Test.stopTest();

        MigrationObjectConfig__c cfg = [
            SELECT ObjectApiName__c, LoadOrder__c, IsActive__c
            FROM MigrationObjectConfig__c WHERE Id = :configId];
        System.assertEquals('Account', cfg.ObjectApiName__c);
        System.assertEquals(1,         cfg.LoadOrder__c);
        System.assertEquals(true,      cfg.IsActive__c);
    }

    @IsTest
    static void addFieldMapping_insertsRecord() {
        Id jobId    = MigrationJobService.createJob('J', false);
        Id configId = MigrationJobService.addObjectConfig(jobId, 'Contact', 1, null);
        Test.startTest();
        Id fmId = MigrationJobService.addFieldMapping(configId, 'Src_AccountId__c', 'AccountId', true, 'Account');
        Test.stopTest();

        MigrationFieldMapping__c fm = [
            SELECT IsParentLookup__c, ParentObjectApiName__c
            FROM MigrationFieldMapping__c WHERE Id = :fmId];
        System.assertEquals(true,       fm.IsParentLookup__c);
        System.assertEquals('Account',  fm.ParentObjectApiName__c);
    }

    @IsTest
    static void loadBatches_createsBatchRecords() {
        Id jobId    = MigrationJobService.createJob('J', false);
        Id configId = MigrationJobService.addObjectConfig(jobId, 'Account', 1, null);

        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        for (Integer i = 0; i < 250; i++) {
            rows.add(new Map<String, Object>{ 'Name' => 'Account ' + i });
        }

        Test.startTest();
        MigrationJobService.loadBatches(jobId, configId, rows);
        Test.stopTest();

        List<MigrationBatch__c> batches = [SELECT BatchSize__c FROM MigrationBatch__c WHERE MigrationJob__c = :jobId];
        System.assertEquals(2, batches.size(), 'Should create 2 batches for 250 rows');

        MigrationJob__c job = [SELECT TotalRecords__c FROM MigrationJob__c WHERE Id = :jobId];
        System.assertEquals(250, job.TotalRecords__c);
    }

    @IsTest
    static void cancelJob_setsStatusCancelled() {
        Id jobId = MigrationJobService.createJob('J', false);
        update new MigrationJob__c(Id = jobId, Status__c = 'InProgress');

        Test.startTest();
        MigrationJobService.cancelJob(jobId);
        Test.stopTest();

        System.assertEquals('Cancelled', [SELECT Status__c FROM MigrationJob__c WHERE Id = :jobId].Status__c);
    }

    @IsTest
    static void startJob_nonDraftStatus_throwsException() {
        Id jobId = MigrationJobService.createJob('J', false);
        update new MigrationJob__c(Id = jobId, Status__c = 'InProgress');

        Test.startTest();
        try {
            MigrationJobService.startJob(jobId);
            System.assert(false, 'Should have thrown MigrationException');
        } catch (MigrationException ex) {
            System.assert(ex.getMessage().contains('Draft'));
        }
        Test.stopTest();
    }

    @IsTest
    static void startRollback_createsRollbackRecord() {
        MigrationJob__c job = MigrationTestDataFactory.createJob(false);
        update new MigrationJob__c(Id = job.Id, Status__c = 'Completed', LoadedCount__c = 0);

        Test.startTest();
        MigrationJobService.startRollback(job.Id);
        Test.stopTest();

        List<MigrationRollback__c> rbs = [SELECT Status__c FROM MigrationRollback__c WHERE MigrationJob__c = :job.Id];
        System.assertEquals(1, rbs.size());
        System.assert(rbs[0].Status__c == 'InProgress' || rbs[0].Status__c == 'Completed',
            'Rollback should be started');
    }
}
