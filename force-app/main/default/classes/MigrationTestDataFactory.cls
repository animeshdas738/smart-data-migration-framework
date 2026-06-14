/**
 * Shared test data builder. Returns fully inserted records so callers
 * can focus on the behaviour under test, not setup boilerplate.
 */
@IsTest
public class MigrationTestDataFactory {

    public static MigrationJob__c createJob(Boolean isDryRun) {
        MigrationJob__c job = new MigrationJob__c(
            JobName__c  = 'Test Job',
            Status__c   = 'Draft',
            IsDryRun__c = isDryRun,
            TotalRecords__c = 0,
            LoadedCount__c  = 0,
            FailedCount__c  = 0
        );
        insert job;
        return job;
    }

    public static MigrationObjectConfig__c createConfig(Id jobId, String objectApiName, Integer loadOrder) {
        MigrationObjectConfig__c cfg = new MigrationObjectConfig__c(
            MigrationJob__c      = jobId,
            ObjectApiName__c     = objectApiName,
            LoadOrder__c         = loadOrder,
            IsActive__c          = true
        );
        insert cfg;
        return cfg;
    }

    public static MigrationFieldMapping__c createMapping(
        Id configId, String source, String target, Boolean isLookup, String parentObj
    ) {
        MigrationFieldMapping__c fm = new MigrationFieldMapping__c(
            MigrationObjectConfig__c = configId,
            SourceFieldName__c       = source,
            TargetFieldApiName__c    = target,
            IsParentLookup__c        = isLookup,
            ParentObjectApiName__c   = parentObj,
            IsActive__c              = true
        );
        insert fm;
        return fm;
    }

    public static MigrationBatch__c createBatch(
        Id jobId, Id configId, Integer seq, String payloadJson, String status
    ) {
        MigrationBatch__c b = new MigrationBatch__c(
            MigrationJob__c          = jobId,
            MigrationObjectConfig__c = configId,
            GlobalBatchSequence__c   = seq,
            BatchSize__c             = 1,
            PayloadJson__c           = payloadJson,
            Status__c                = status
        );
        insert b;
        return b;
    }

    public static MigrationRollback__c createRollback(Id jobId, String status) {
        MigrationRollback__c rb = new MigrationRollback__c(
            MigrationJob__c = jobId,
            Status__c       = status
        );
        insert rb;
        return rb;
    }
}
