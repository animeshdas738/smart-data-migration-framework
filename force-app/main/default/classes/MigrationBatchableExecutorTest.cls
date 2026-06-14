@IsTest
private class MigrationBatchableExecutorTest {

    @IsTest
    static void validateMode_noErrors_transitionsToInProgress() {
        MigrationJob__c job = MigrationTestDataFactory.createJob(false);
        MigrationObjectConfig__c cfg = MigrationTestDataFactory.createConfig(job.Id, 'Account', 1);
        MigrationTestDataFactory.createMapping(cfg.Id, 'Name', 'Name', false, null);
        String payload = JSON.serialize(new List<Map<String,Object>>{
            new Map<String,Object>{ 'Id' => 'L001', 'Name' => 'Acme' }
        });
        MigrationTestDataFactory.createBatch(job.Id, cfg.Id, 1, payload, 'Pending');
        update new MigrationJob__c(Id = job.Id, Status__c = 'Validating');

        Test.startTest();
        Database.executeBatch(new MigrationBatchableExecutor(job.Id, 'Validate'), 200);
        Test.stopTest();

        MigrationJob__c updated = [SELECT Status__c FROM MigrationJob__c WHERE Id = :job.Id];
        System.assert(
            updated.Status__c == 'InProgress' || updated.Status__c == 'Completed',
            'Job should be InProgress or Completed after valid validation pass, got: ' + updated.Status__c);
    }

    @IsTest
    static void validateMode_dryRun_marksDryRunPassed() {
        MigrationJob__c job = MigrationTestDataFactory.createJob(true);
        MigrationObjectConfig__c cfg = MigrationTestDataFactory.createConfig(job.Id, 'Account', 1);
        MigrationTestDataFactory.createMapping(cfg.Id, 'Name', 'Name', false, null);
        String payload = JSON.serialize(new List<Map<String,Object>>{
            new Map<String,Object>{ 'Id' => 'L001', 'Name' => 'Acme' }
        });
        MigrationTestDataFactory.createBatch(job.Id, cfg.Id, 1, payload, 'Pending');
        update new MigrationJob__c(Id = job.Id, Status__c = 'Validating');

        Test.startTest();
        Database.executeBatch(new MigrationBatchableExecutor(job.Id, 'Validate'), 200);
        Test.stopTest();

        String status = [SELECT Status__c FROM MigrationJob__c WHERE Id = :job.Id].Status__c;
        System.assertEquals('DryRunPassed', status);
    }

    @IsTest
    static void doRollbackMode_constructsWithoutError() {
        MigrationJob__c job = MigrationTestDataFactory.createJob(false);
        Test.startTest();
        MigrationBatchableExecutor exec = new MigrationBatchableExecutor(job.Id, 'DoRollback');
        System.assertNotEquals(null, exec);
        Test.stopTest();
    }
}
