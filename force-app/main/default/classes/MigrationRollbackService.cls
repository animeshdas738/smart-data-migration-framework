/**
 * Orchestrates reverse-order deletion of all records created by a migration job.
 * Delete order is the inverse of LoadOrder__c so child records are deleted before parents.
 * Implemented as Batchable to handle jobs with millions of migrated records.
 */
public with sharing class MigrationRollbackService implements Database.Batchable<SObject>, Database.Stateful {

    private final Id   rollbackId;
    private final Id   jobId;
    private       Integer currentLoadOrder;
    private       Integer deletedCount = 0;
    private       Integer errorCount   = 0;

    // ─── Entry point ─────────────────────────────────────────────────────────

    public static Id startRollback(Id rollbackRecordId) {
        MigrationRollback__c rb = [
            SELECT Id, MigrationJob__c, Status__c
            FROM MigrationRollback__c
            WHERE Id = :rollbackRecordId
            LIMIT 1
        ];

        if (rb.Status__c != 'Pending') {
            throw new MigrationException('Rollback ' + rollbackRecordId + ' is not in Pending status.');
        }

        rb.Status__c = 'InProgress';
        update rb;

        // Find the highest LoadOrder present in logs (start deleting from there DESC)
        AggregateResult[] maxOrder = [
            SELECT MAX(LoadOrder__c) maxOrder
            FROM MigrationRecordLog__c
            WHERE MigrationJob__c = :rb.MigrationJob__c
        ];
        Integer maxLoadOrder = maxOrder[0].get('maxOrder') != null
            ? Integer.valueOf(maxOrder[0].get('maxOrder'))
            : 0;

        MigrationRollbackService svc = new MigrationRollbackService(rollbackRecordId, rb.MigrationJob__c, maxLoadOrder);
        return Database.executeBatch(svc, 200);
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

    public MigrationRollbackService(Id rollbackId, Id jobId, Integer startLoadOrder) {
        this.rollbackId       = rollbackId;
        this.jobId            = jobId;
        this.currentLoadOrder = startLoadOrder;
    }

    // ─── Batchable interface ─────────────────────────────────────────────────

    public Database.QueryLocator start(Database.BatchableContext bc) {
        // Process one load-order tier at a time; each batch handles 200 records within that tier
        return Database.getQueryLocator([
            SELECT Id, SalesforceId__c, ObjectApiName__c, LoadOrder__c
            FROM MigrationRecordLog__c
            WHERE MigrationJob__c = :jobId
              AND LoadOrder__c     = :currentLoadOrder
              AND SalesforceId__c != null
        ]);
    }

    public void execute(Database.BatchableContext bc, List<MigrationRecordLog__c> scope) {
        // Collect Salesforce IDs to delete
        List<Id> idsToDelete = new List<Id>();
        Map<Id, Id> sfIdToLogId = new Map<Id, Id>();
        for (MigrationRecordLog__c log : scope) {
            Id sfId = (Id) log.SalesforceId__c;
            if (sfId != null) {
                idsToDelete.add(sfId);
                sfIdToLogId.put(sfId, log.Id);
            }
        }

        if (idsToDelete.isEmpty()) {
            return;
        }

        List<Database.DeleteResult> results = Database.delete(idsToDelete, false);
        List<Id> successLogIds = new List<Id>();
        for (Integer i = 0; i < results.size(); i++) {
            Database.DeleteResult dr = results[i];
            if (dr.isSuccess()) {
                deletedCount++;
                successLogIds.add(sfIdToLogId.get(idsToDelete[i]));
            } else {
                errorCount++;
                System.debug(LoggingLevel.ERROR,
                    'Rollback delete failed for ' + idsToDelete[i] + ': ' + dr.getErrors()[0].getMessage());
            }
        }

        // Null out SalesforceId__c on successfully deleted log rows so re-runs are idempotent
        if (!successLogIds.isEmpty()) {
            List<MigrationRecordLog__c> toUpdate = new List<MigrationRecordLog__c>();
            for (Id logId : successLogIds) {
                toUpdate.add(new MigrationRecordLog__c(Id = logId, SalesforceId__c = null));
            }
            update toUpdate;
        }
    }

    public void finish(Database.BatchableContext bc) {
        // Move to the next lower load order tier, or wrap up if done
        Integer nextOrder = currentLoadOrder - 1;

        if (nextOrder >= 1) {
            // Requeue for the next tier
            MigrationRollbackService nextSvc = new MigrationRollbackService(rollbackId, jobId, nextOrder);
            Database.executeBatch(nextSvc, 200);
        } else {
            // All tiers processed — finalize the rollback record
            String finalStatus = errorCount > 0 ? 'CompletedWithErrors' : 'Completed';
            update new MigrationRollback__c(
                Id              = rollbackId,
                Status__c       = finalStatus,
                CompletedAt__c  = Datetime.now(),
                DeletedCount__c = deletedCount,
                FailedDeleteCount__c   = errorCount
            );

            // Reset the parent job status
            update new MigrationJob__c(
                Id           = jobId,
                Status__c    = 'RolledBack',
                LoadedCount__c = 0
            );
        }
    }
}
