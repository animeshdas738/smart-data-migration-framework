/**
 * Batchable for two use cases:
 *   1. Mode = 'Validate'  — runs MigrationValidationEngine across all batches before any DML.
 *   2. Mode = 'DoRollback' — no-op here; use MigrationRollbackService.startRollback() directly.
 *
 * Usage:
 *   Database.executeBatch(new MigrationBatchableExecutor(jobId, 'Validate'), 200);
 */
public with sharing class MigrationBatchableExecutor
    implements Database.Batchable<SObject>, Database.Stateful {

    public enum RunMode { Validate, DoRollback }

    private final Id      jobId;
    private final RunMode execMode;   // named execMode to avoid case-insensitive clash with RunMode type
    private       Integer totalErrors = 0;

    private MigrationValidationEngine engine = new MigrationValidationEngine();

    public MigrationBatchableExecutor(Id jobId, String mode) {
        this.jobId    = jobId;
        this.execMode = (mode == 'Validate') ? RunMode.Validate : RunMode.DoRollback;
    }

    // ─── Batchable ───────────────────────────────────────────────────────────

    public Database.QueryLocator start(Database.BatchableContext bc) {
        if (execMode == RunMode.Validate) {
            return Database.getQueryLocator([
                SELECT Id, MigrationJob__c, MigrationObjectConfig__c, PayloadJson__c,
                       GlobalBatchSequence__c
                FROM MigrationBatch__c
                WHERE MigrationJob__c = :jobId
                  AND Status__c       = 'Pending'
                ORDER BY GlobalBatchSequence__c ASC
            ]);
        } else {
            // DoRollback path is handled by MigrationRollbackService; return an empty locator
            return Database.getQueryLocator([
                SELECT Id FROM MigrationRecordLog__c WHERE Id = null
            ]);
        }
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        if (execMode == RunMode.Validate) {
            runValidation(scope);
        }
    }

    public void finish(Database.BatchableContext bc) {
        if (execMode == RunMode.Validate) {
            MigrationJob__c job = [
                SELECT Id, Status__c, IsDryRun__c
                FROM MigrationJob__c
                WHERE Id = :jobId
                LIMIT 1
            ];

            if (totalErrors > 0) {
                update new MigrationJob__c(
                    Id        = jobId,
                    Status__c = 'ValidationFailed'
                );
            } else if (job.IsDryRun__c) {
                update new MigrationJob__c(
                    Id             = jobId,
                    Status__c      = 'DryRunPassed',
                    CompletedAt__c = Datetime.now()
                );
            } else {
                update new MigrationJob__c(
                    Id        = jobId,
                    Status__c = 'InProgress'
                );
                System.enqueueJob(new MigrationBatchExecutor(jobId, 1));
            }
        }
    }

    // ─── Validation pass ─────────────────────────────────────────────────────

    private void runValidation(List<SObject> scope) {
        List<MigrationBatch__c> batches = (List<MigrationBatch__c>) scope;

        Set<Id> configIds = new Set<Id>();
        for (MigrationBatch__c b : batches) {
            configIds.add(b.MigrationObjectConfig__c);
        }

        Map<Id, MigrationObjectConfig__c> configCache = new Map<Id, MigrationObjectConfig__c>();
        for (MigrationObjectConfig__c cfg : [
            SELECT Id, ObjectApiName__c, LoadOrder__c
            FROM MigrationObjectConfig__c
            WHERE Id IN :configIds
        ]) {
            configCache.put(cfg.Id, cfg);
        }

        Map<Id, List<MigrationFieldMapping__c>> mappingCache = new Map<Id, List<MigrationFieldMapping__c>>();
        for (MigrationFieldMapping__c fm : [
            SELECT Id, MigrationObjectConfig__c, SourceFieldName__c, TargetFieldApiName__c,
                   IsRequired__c, IsParentLookup__c, ParentObjectApiName__c
            FROM MigrationFieldMapping__c
            WHERE MigrationObjectConfig__c IN :configIds
              AND IsActive__c = true
        ]) {
            if (!mappingCache.containsKey(fm.MigrationObjectConfig__c)) {
                mappingCache.put(fm.MigrationObjectConfig__c, new List<MigrationFieldMapping__c>());
            }
            mappingCache.get(fm.MigrationObjectConfig__c).add(fm);
        }

        List<MigrationRowError__c> allErrors = new List<MigrationRowError__c>();

        for (MigrationBatch__c batch : batches) {
            MigrationObjectConfig__c config = configCache.get(batch.MigrationObjectConfig__c);
            List<MigrationFieldMapping__c> fieldMaps = mappingCache.containsKey(batch.MigrationObjectConfig__c)
                ? mappingCache.get(batch.MigrationObjectConfig__c)
                : new List<MigrationFieldMapping__c>();

            List<Map<String, Object>> rows = String.isNotBlank(batch.PayloadJson__c)
                ? (List<Map<String, Object>>) JSON.deserializeUntyped(batch.PayloadJson__c)
                : new List<Map<String, Object>>();

            MigrationValidationEngine.ValidationResult result =
                engine.validateBatch(rows, config, fieldMaps, batch);

            allErrors.addAll(result.errors);
            totalErrors += result.errorCount;
        }

        if (!allErrors.isEmpty()) {
            insert allErrors;
        }
    }
}
