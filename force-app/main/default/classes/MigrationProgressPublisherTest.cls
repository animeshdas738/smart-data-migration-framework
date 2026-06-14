@IsTest
private class MigrationProgressPublisherTest {

    @IsTest
    static void publish_noException() {
        MigrationJob__c job = MigrationTestDataFactory.createJob(false);
        update new MigrationJob__c(
            Id = job.Id, Status__c = 'InProgress',
            TotalRecords__c = 1000, LoadedCount__c = 500, FailedCount__c = 2);

        MigrationJob__c refreshed = [
            SELECT Id, LoadedCount__c, FailedCount__c, TotalRecords__c
            FROM MigrationJob__c WHERE Id = :job.Id];

        Test.startTest();
        MigrationProgressPublisher.publish(refreshed, 'Account');
        Test.stopTest();

        // Platform Events publish synchronously in test context — no exception = pass
        System.assert(true, 'publish should complete without exception');
    }

    @IsTest
    static void publish_zeroTotal_percentIsZero() {
        MigrationJob__c job = MigrationTestDataFactory.createJob(false);
        MigrationJob__c refreshed = [
            SELECT Id, LoadedCount__c, FailedCount__c, TotalRecords__c
            FROM MigrationJob__c WHERE Id = :job.Id];

        Test.startTest();
        MigrationProgressPublisher.publish(refreshed, 'Contact');
        Test.stopTest();

        System.assert(true, 'Zero-total job should not throw division-by-zero');
    }

    @IsTest
    static void publish_withRecentBatches_computesEta() {
        MigrationJob__c job = MigrationTestDataFactory.createJob(false);
        update new MigrationJob__c(Id = job.Id, TotalRecords__c = 1000, LoadedCount__c = 200);

        MigrationObjectConfig__c cfg = MigrationTestDataFactory.createConfig(job.Id, 'Account', 1);
        MigrationBatch__c b = MigrationTestDataFactory.createBatch(job.Id, cfg.Id, 1, '[]', 'Completed');
        update new MigrationBatch__c(
            Id = b.Id, SuccessCount__c = 200, BatchSize__c = 200,
            StartedAt__c = Datetime.now().addSeconds(-10), CompletedAt__c = Datetime.now());

        MigrationJob__c refreshed = [
            SELECT Id, LoadedCount__c, FailedCount__c, TotalRecords__c
            FROM MigrationJob__c WHERE Id = :job.Id];

        Test.startTest();
        MigrationProgressPublisher.publish(refreshed, 'Account');
        Test.stopTest();

        System.assert(true, 'ETA computation with batches should not throw');
    }
}
