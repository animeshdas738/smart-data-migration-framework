/**
 * Queueable chain that loads one 200-row batch per enqueue.
 * Chain continues by re-enqueuing itself with the next batch sequence number.
 * Checkpoint resume: reads LastCompletedBatchSequence__c on the job and skips ahead.
 *
 * Governor limits per execution:
 *   DML rows : 200 source records + up to 200 log records = 400 (within 10,000 limit)
 *   SOQL     : ~6–10 queries (config, batch, parent ID map lookup, update job counters)
 *   Heap     : <2 MB when Platform Cache carries the ID map
 */
public class MigrationBatchExecutor implements Queueable, Database.AllowsCallouts {

    private final Id     jobId;
    private final Integer batchSequence;  // global monotonic sequence number to execute next

    public MigrationBatchExecutor(Id jobId, Integer batchSequence) {
        this.jobId         = jobId;
        this.batchSequence = batchSequence;
    }

    // ─── Queueable ───────────────────────────────────────────────────────────

    public void execute(QueueableContext ctx) {
        MigrationJob__c job = fetchJob();
        if (job == null || shouldAbort(job)) {
            return;
        }

        // Checkpoint resume: skip batches already committed
        Integer startFrom = job.LastCompletedBatchSequence__c != null
            ? Integer.valueOf(job.LastCompletedBatchSequence__c) + 1
            : batchSequence;

        MigrationBatch__c batch = fetchBatch(startFrom);
        if (batch == null) {
            // No more batches — job is complete
            finalizeJob(job);
            return;
        }

        // Determine if this is the two-pass second pass (self-referential update)
        Boolean isSelfRefPass2 = batch.IsSecondPass__c == true;

        // Fetch object config and field mappings
        MigrationObjectConfig__c config = fetchConfig(batch.MigrationObjectConfig__c);
        // Store objectApiName before scope narrows
        String objectApiName = config.ObjectApiName__c;
        List<MigrationFieldMapping__c> fieldMaps = fetchFieldMappings(config.Id);

        // Deserialize source rows from the batch payload
        List<Map<String, Object>> sourceRows = deserializePayload(batch.PayloadJson__c);
        if (sourceRows == null || sourceRows.isEmpty()) {
            advanceAndEnqueue(job, batch, 0, 0);
            return;
        }

        // Build the SObjects to insert/upsert
        List<SObject> records = new List<SObject>();
        Map<Integer, String> indexToLegacyId = new Map<Integer, String>();
        Map<String, Id> parentIdMap = isSelfRefPass2
            ? MigrationIdCache.get(jobId, config.ObjectApiName__c)
            : buildParentIdMap(config, fieldMaps);

        Schema.SObjectType sot = Schema.getGlobalDescribe().get(config.ObjectApiName__c);

        for (Integer i = 0; i < sourceRows.size(); i++) {
            Map<String, Object> row = sourceRows[i];
            SObject rec = sot.newSObject();

            String legacyId = String.valueOf(row.get('Id'));
            indexToLegacyId.put(i, legacyId);

            for (MigrationFieldMapping__c fm : fieldMaps) {
                Object rawVal = row.get(fm.SourceFieldName__c);
                if (rawVal == null) {
                    continue;
                }

                // Relationship field: translate legacy parent ID → SF Id
                if (fm.IsParentLookup__c && parentIdMap != null) {
                    Id translatedId = parentIdMap.get(String.valueOf(rawVal));
                    if (translatedId != null) {
                        rec.put(fm.TargetFieldApiName__c, translatedId);
                    } else if (isSelfRefPass2) {
                        rec.put(fm.TargetFieldApiName__c, null);
                    }
                } else {
                    rec.put(fm.TargetFieldApiName__c, rawVal);
                }
            }

            // On pass 2 of self-ref: set the Id so we UPDATE not INSERT
            if (isSelfRefPass2) {
                Id sfId = parentIdMap.get(legacyId);
                if (sfId != null) {
                    rec.put('Id', sfId);
                }
            }

            records.add(rec);
        }

        // DML — allOrNone = false for partial success
        Datetime batchStart = Datetime.now();
        Integer loaded = 0;
        Integer failed = 0;
        List<MigrationRowError__c> errors = new List<MigrationRowError__c>();
        List<MigrationRecordLog__c> logs  = new List<MigrationRecordLog__c>();

        if (isSelfRefPass2) {
            List<Database.SaveResult> results = Database.update(records, false);
            processResults(results, indexToLegacyId, batch, config, logs, errors);
            for (Database.SaveResult sr : results) {
                if (sr.isSuccess()) loaded++; else failed++;
            }
        } else if (config.ExternalIdField__c != null) {
            Schema.SObjectField extIdField = sot.getDescribe().fields.getMap()
                .get(config.ExternalIdField__c.toLowerCase());
            List<Database.UpsertResult> results = Database.upsert(records, extIdField, false);
            processUpsertResults(results, indexToLegacyId, batch, config, logs, errors);
            for (Database.UpsertResult ur : results) {
                if (ur.isSuccess()) loaded++; else failed++;
            }
        } else {
            List<Database.SaveResult> results = Database.insert(records, false);
            processResults(results, indexToLegacyId, batch, config, logs, errors);
            for (Database.SaveResult sr : results) {
                if (sr.isSuccess()) loaded++; else failed++;
            }
        }

        // Write logs and errors
        if (!logs.isEmpty()) {
            insert logs;
            // Cache the ID map for child object batches
            Map<String, Id> newMap = new Map<String, Id>();
            for (MigrationRecordLog__c l : logs) {
                if (l.LegacyId__c != null && l.SalesforceId__c != null) {
                    newMap.put(l.LegacyId__c, (Id) l.SalesforceId__c);
                }
            }
            if (!newMap.isEmpty()) {
                // Merge into existing cache rather than replacing
                Map<String, Id> existingMap = MigrationIdCache.get(jobId, config.ObjectApiName__c);
                existingMap.putAll(newMap);
                MigrationIdCache.put(jobId, config.ObjectApiName__c, existingMap);
            }
        }
        if (!errors.isEmpty()) {
            insert errors;
        }

        advanceAndEnqueue(job, batch, loaded, failed);

        // Publish progress event
        MigrationJob__c refreshedJob = fetchJob();
        if (refreshedJob != null) {
            MigrationProgressPublisher.publish(refreshedJob, config.ObjectApiName__c);
        }
    }

    // ─── DML result processors ───────────────────────────────────────────────

    private void processResults(
        List<Database.SaveResult> results,
        Map<Integer, String> indexToLegacyId,
        MigrationBatch__c batch,
        MigrationObjectConfig__c config,
        List<MigrationRecordLog__c> logs,
        List<MigrationRowError__c> errors
    ) {
        for (Integer i = 0; i < results.size(); i++) {
            Database.SaveResult sr = results[i];
            String legacyId = indexToLegacyId.get(i);
            if (sr.isSuccess()) {
                logs.add(new MigrationRecordLog__c(
                    MigrationJob__c       = jobId,
                    MigrationBatch__c     = batch.Id,
                    LegacyId__c           = legacyId,
                    SalesforceId__c       = sr.getId(),
                    ObjectApiName__c      = config.ObjectApiName__c,
                    LoadOrder__c          = config.LoadOrder__c
                ));
            } else {
                errors.add(new MigrationRowError__c(
                    MigrationBatch__c = batch.Id,
                    MigrationJob__c   = jobId,
                    RowNumber__c      = i,
                    SourceExternalId__c = legacyId,
                    ErrorMessage__c   = sr.getErrors()[0].getMessage(),
                    Phase__c          = 'DML'
                ));
            }
        }
    }

    private void processUpsertResults(
        List<Database.UpsertResult> results,
        Map<Integer, String> indexToLegacyId,
        MigrationBatch__c batch,
        MigrationObjectConfig__c config,
        List<MigrationRecordLog__c> logs,
        List<MigrationRowError__c> errors
    ) {
        for (Integer i = 0; i < results.size(); i++) {
            Database.UpsertResult ur = results[i];
            String legacyId = indexToLegacyId.get(i);
            if (ur.isSuccess()) {
                logs.add(new MigrationRecordLog__c(
                    MigrationJob__c       = jobId,
                    MigrationBatch__c     = batch.Id,
                    LegacyId__c           = legacyId,
                    SalesforceId__c       = ur.getId(),
                    ObjectApiName__c      = config.ObjectApiName__c,
                    LoadOrder__c          = config.LoadOrder__c
                ));
            } else {
                errors.add(new MigrationRowError__c(
                    MigrationBatch__c   = batch.Id,
                    MigrationJob__c     = jobId,
                    RowNumber__c        = i,
                    SourceExternalId__c = legacyId,
                    ErrorMessage__c     = ur.getErrors()[0].getMessage(),
                    Phase__c            = 'DML'
                ));
            }
        }
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    private MigrationJob__c fetchJob() {
        List<MigrationJob__c> jobs = [
            SELECT Id, Status__c, LoadedCount__c, FailedCount__c, TotalRecords__c,
                   LastCompletedBatchSequence__c, IsDryRun__c
            FROM MigrationJob__c
            WHERE Id = :jobId
            LIMIT 1
        ];
        return jobs.isEmpty() ? null : jobs[0];
    }

    private Boolean shouldAbort(MigrationJob__c job) {
        return job.Status__c == 'Cancelled' || job.Status__c == 'Failed'
            || job.Status__c == 'Completed' || job.Status__c == 'RolledBack';
    }

    private MigrationBatch__c fetchBatch(Integer seq) {
        List<MigrationBatch__c> batches = [
            SELECT Id, MigrationJob__c, MigrationObjectConfig__c, GlobalBatchSequence__c,
                   PayloadJson__c, BatchSize__c, StartedAt__c, IsCheckpoint__c, IsSecondPass__c
            FROM MigrationBatch__c
            WHERE MigrationJob__c        = :jobId
              AND GlobalBatchSequence__c = :seq
            LIMIT 1
        ];
        return batches.isEmpty() ? null : batches[0];
    }

    private MigrationObjectConfig__c fetchConfig(Id configId) {
        return [
            SELECT Id, ObjectApiName__c, LoadOrder__c, ExternalIdField__c,
                   SelfReferenceField__c
            FROM MigrationObjectConfig__c
            WHERE Id = :configId
            LIMIT 1
        ];
    }

    private List<MigrationFieldMapping__c> fetchFieldMappings(Id configId) {
        return [
            SELECT SourceFieldName__c, TargetFieldApiName__c, IsParentLookup__c,
                   ParentObjectApiName__c, IsRequired__c
            FROM MigrationFieldMapping__c
            WHERE MigrationObjectConfig__c = :configId
              AND IsActive__c = true
        ];
    }

    private Map<String, Id> buildParentIdMap(
        MigrationObjectConfig__c config,
        List<MigrationFieldMapping__c> fieldMaps
    ) {
        // Collect all parent object API names referenced by relationship fields
        Set<String> parentObjects = new Set<String>();
        for (MigrationFieldMapping__c fm : fieldMaps) {
            if (fm.IsParentLookup__c && fm.ParentObjectApiName__c != null) {
                parentObjects.add(fm.ParentObjectApiName__c);
            }
        }
        if (parentObjects.isEmpty()) {
            return new Map<String, Id>();
        }
        // For simplicity, return the map for the first parent object
        // In practice, the executor handles one FK at a time per field mapping
        Map<String, Id> combined = new Map<String, Id>();
        for (String parentObj : parentObjects) {
            combined.putAll(MigrationIdCache.get(jobId, parentObj));
        }
        return combined;
    }

    private List<Map<String, Object>> deserializePayload(String payloadStr) {
        if (String.isBlank(payloadStr)) {
            return new List<Map<String, Object>>();
        }
        return (List<Map<String, Object>>) JSON.deserializeUntyped(payloadStr);
    }

    private void advanceAndEnqueue(MigrationJob__c job, MigrationBatch__c batch, Integer loaded, Integer failed) {
        // Update batch record
        update new MigrationBatch__c(
            Id              = batch.Id,
            Status__c       = 'Completed',
            CompletedAt__c  = Datetime.now(),
            SuccessCount__c = loaded,
            FailureCount__c = failed,
            IsCheckpoint__c = true
        );

        // Update job counters
        update new MigrationJob__c(
            Id                             = jobId,
            LoadedCount__c                 = (job.LoadedCount__c != null ? job.LoadedCount__c : 0) + loaded,
            FailedCount__c                 = (job.FailedCount__c != null ? job.FailedCount__c : 0) + failed,
            LastCompletedBatchSequence__c  = batch.GlobalBatchSequence__c
        );

        // Enqueue next batch
        Integer nextSeq = Integer.valueOf(batch.GlobalBatchSequence__c) + 1;
        if (!Test.isRunningTest()) {
            System.enqueueJob(new MigrationBatchExecutor(jobId, nextSeq));
        }
    }

    private void finalizeJob(MigrationJob__c job) {
        update new MigrationJob__c(
            Id          = jobId,
            Status__c   = 'Completed',
            CompletedAt__c = Datetime.now()
        );
    }
}
