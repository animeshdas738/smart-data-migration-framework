/**
 * Publishes MigrationProgressEvent__e after each committed batch.
 * Computes ETA from a rolling throughput average over the last 5 batches.
 */
public with sharing class MigrationProgressPublisher {

    private static final Integer ROLLING_WINDOW = 5;

    public static void publish(MigrationJob__c job, String currentObjectName) {
        Decimal pct = (job.TotalRecords__c != null && job.TotalRecords__c > 0)
            ? ((job.LoadedCount__c != null ? job.LoadedCount__c : 0) / job.TotalRecords__c) * 100
            : 0;

        MigrationProgressEvent__e evt = new MigrationProgressEvent__e(
            JobId__c              = job.Id,
            LoadedCount__c        = job.LoadedCount__c != null ? job.LoadedCount__c : 0,
            FailedCount__c        = job.FailedCount__c != null ? job.FailedCount__c : 0,
            PercentComplete__c    = pct.setScale(2),
            CurrentObjectName__c  = currentObjectName,
            EstimatedCompletionAt__c = computeEta(job)
        );

        Database.SaveResult sr = EventBus.publish(evt);
        if (!sr.isSuccess()) {
            System.debug(LoggingLevel.WARN,
                'MigrationProgressPublisher: publish failed — ' + sr.getErrors()[0].getMessage());
        }
    }

    // ─── ETA ──────────────────────────────────────────────────────────────────

    private static Datetime computeEta(MigrationJob__c job) {
        if (job.TotalRecords__c == null || job.TotalRecords__c == 0
                || job.LoadedCount__c == null || job.LoadedCount__c == 0) {
            return null;
        }

        // Average seconds-per-record from the last N completed batches
        List<MigrationBatch__c> recentBatches = [
            SELECT DurationSeconds__c, BatchSize__c
            FROM MigrationBatch__c
            WHERE MigrationJob__c = :job.Id
              AND Status__c = 'Completed'
              AND DurationSeconds__c != null
              AND BatchSize__c != null
              AND BatchSize__c > 0
            ORDER BY GlobalBatchSequence__c DESC
            LIMIT :ROLLING_WINDOW
        ];

        if (recentBatches.isEmpty()) {
            return null;
        }

        Decimal totalSecs = 0;
        Decimal totalRecs = 0;
        for (MigrationBatch__c b : recentBatches) {
            totalSecs += b.DurationSeconds__c;
            totalRecs += b.BatchSize__c;
        }

        Decimal secsPerRecord = totalSecs / totalRecs;
        Decimal remaining = job.TotalRecords__c - job.LoadedCount__c;
        Long etaMs = (Long)(secsPerRecord * remaining * 1000);
        return Datetime.now().addSeconds((Integer) Math.min(etaMs / 1000, 2147483647));
    }
}
