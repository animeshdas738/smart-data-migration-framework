/**
 * Top-level public API for the Smart Data Migration Framework.
 *
 * Typical caller flow:
 *   Id jobId = MigrationJobService.createJob('Q4 Account Migration', false);
 *   MigrationJobService.addObjectConfig(jobId, 'Account', 1, null);
 *   MigrationJobService.addFieldMapping(configId, 'Name__c', 'Name', false, null);
 *   MigrationJobService.loadBatches(jobId, 'Account', listOfRowMaps);
 *   MigrationJobService.startJob(jobId);
 */
public with sharing class MigrationJobService {

    // ─── Job lifecycle ───────────────────────────────────────────────────────

    /**
     * Creates a new MigrationJob__c in Draft status.
     * @param jobName  Human-readable name shown in reports
     * @param isDryRun When true, the validation pass runs but no DML is committed
     */
    public static Id createJob(String jobName, Boolean isDryRun) {
        MigrationJob__c job = new MigrationJob__c(
            JobName__c    = jobName,
            Status__c     = 'Draft',
            IsDryRun__c   = isDryRun,
            StartedAt__c  = null
        );
        insert job;
        return job.Id;
    }

    /**
     * Adds an object to the job's migration scope.
     * @param loadOrder        Initial ordering hint (resolver will recalculate)
     * @param externalIdField  API name of the external-ID field for upsert, or null for insert
     */
    public static Id addObjectConfig(
        Id     jobId,
        String targetObjectApiName,
        Integer loadOrder,
        String externalIdField
    ) {
        MigrationObjectConfig__c config = new MigrationObjectConfig__c(
            MigrationJob__c      = jobId,
            ObjectApiName__c     = targetObjectApiName,
            LoadOrder__c         = loadOrder,
            ExternalIdField__c   = externalIdField,
            IsActive__c          = true
        );
        insert config;
        return config.Id;
    }

    /**
     * Adds a field mapping for an object config.
     * @param isRelationship         True when the source value is a legacy parent ID
     * @param relatedObjectApiName   Required when isRelationship = true
     */
    public static Id addFieldMapping(
        Id     configId,
        String sourceFieldName,
        String targetFieldApiName,
        Boolean isRelationship,
        String relatedObjectApiName
    ) {
        MigrationFieldMapping__c fm = new MigrationFieldMapping__c(
            MigrationObjectConfig__c = configId,
            SourceFieldName__c       = sourceFieldName,
            TargetFieldApiName__c    = targetFieldApiName,
            IsParentLookup__c        = isRelationship,
            ParentObjectApiName__c   = relatedObjectApiName,
            IsActive__c              = true
        );
        insert fm;
        return fm.Id;
    }

    /**
     * Adds an explicit parent → child dependency edge for the relationship resolver.
     */
    public static void addDependency(Id parentConfigId, Id childConfigId) {
        insert new MigrationObjectDependency__c(
            ParentObjectConfig__c = parentConfigId,
            ChildObjectConfig__c  = childConfigId
        );
    }

    /**
     * Partitions source rows into 200-row MigrationBatch__c records and persists them
     * with their JSON payload. Call once per source object before startJob().
     *
     * @param rows  List of Map<sourceField, value> — one entry per source record
     */
    public static void loadBatches(Id jobId, Id configId, List<Map<String, Object>> rows) {
        if (rows == null || rows.isEmpty()) {
            return;
        }

        final Integer BATCH_SIZE = 200;

        // Find the current max GlobalBatchSequence for this job to continue from
        AggregateResult[] agg = [
            SELECT MAX(GlobalBatchSequence__c) maxSeq
            FROM MigrationBatch__c
            WHERE MigrationJob__c = :jobId
        ];
        Integer nextSeq = agg[0].get('maxSeq') != null
            ? Integer.valueOf(agg[0].get('maxSeq')) + 1
            : 1;

        List<MigrationBatch__c> batches = new List<MigrationBatch__c>();
        Integer i = 0;
        while (i < rows.size()) {
            Integer endIdx = Math.min(i + BATCH_SIZE, rows.size());
            List<Map<String, Object>> chunk = new List<Map<String, Object>>();
            for (Integer j = i; j < endIdx; j++) {
                chunk.add(rows[j]);
            }
            batches.add(new MigrationBatch__c(
                MigrationJob__c           = jobId,
                MigrationObjectConfig__c  = configId,
                GlobalBatchSequence__c    = nextSeq,
                BatchSize__c              = chunk.size(),
                PayloadJson__c            = JSON.serialize(chunk),
                Status__c                 = 'Pending'
            ));
            nextSeq++;
            i += BATCH_SIZE;
        }

        insert batches;

        // Update job total record count
        MigrationJob__c job = [SELECT Id, TotalRecords__c FROM MigrationJob__c WHERE Id = :jobId LIMIT 1];
        job.TotalRecords__c = (job.TotalRecords__c != null ? job.TotalRecords__c : 0) + rows.size();
        update job;
    }

    /**
     * Resolves object load order, then launches the validation batch.
     * The validation batch will auto-start the Queueable load chain on success
     * (or mark ValidationFailed if errors found).
     */
    public static void startJob(Id jobId) {
        MigrationJob__c job = [
            SELECT Id, Status__c
            FROM MigrationJob__c
            WHERE Id = :jobId
            LIMIT 1
        ];
        if (job.Status__c != 'Draft') {
            throw new MigrationException(
                'Job ' + jobId + ' must be in Draft status to start (current: ' + job.Status__c + ')');
        }

        // Resolve topological order
        MigrationRelationshipResolver resolver = new MigrationRelationshipResolver();
        MigrationRelationshipResolver.ResolutionResult resolution = resolver.resolve(jobId);
        if (!resolution.success) {
            update new MigrationJob__c(Id = jobId, Status__c = 'Failed',
                ErrorMessage__c = resolution.errorMessage);
            throw new MigrationException('Dependency resolution failed: ' + resolution.errorMessage);
        }

        // Transition job to Validating
        update new MigrationJob__c(
            Id          = jobId,
            Status__c   = 'Validating',
            StartedAt__c = Datetime.now()
        );

        // Run validation batchable; it will start the Queueable chain on success
        Database.executeBatch(new MigrationBatchableExecutor(jobId, 'Validate'), 200);
    }

    /**
     * Cancels a running job. The Queueable chain checks Status__c before each batch and will
     * stop naturally within one batch execution (~seconds).
     */
    public static void cancelJob(Id jobId) {
        update new MigrationJob__c(Id = jobId, Status__c = 'Cancelled');
    }

    /**
     * Initiates a rollback. Creates a MigrationRollback__c record and starts the
     * reverse-delete Batchable.
     */
    public static Id startRollback(Id jobId) {
        MigrationRollback__c rb = new MigrationRollback__c(
            MigrationJob__c = jobId,
            Status__c       = 'Pending'
        );
        insert rb;
        return MigrationRollbackService.startRollback(rb.Id);
    }
}
