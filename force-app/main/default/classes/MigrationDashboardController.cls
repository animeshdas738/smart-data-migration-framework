/**
 * @AuraEnabled controller for migrationDashboard and migrationJobConfig LWCs.
 * Thin wrapper around MigrationJobService — keeps LWC imports to a single class.
 */
public with sharing class MigrationDashboardController {

    @AuraEnabled(cacheable=true)
    public static List<MigrationJob__c> getActiveJobs() {
        return [
            SELECT Id, JobName__c, Status__c, LoadedCount__c, FailedCount__c,
                   TotalRecords__c, PercentComplete__c, StartedAt__c, CompletedAt__c,
                   IsDryRun__c, ErrorMessage__c
            FROM MigrationJob__c
            WHERE Status__c NOT IN ('Draft', 'Completed', 'DryRunPassed', 'RolledBack', 'Cancelled')
               OR (Status__c IN ('Completed', 'DryRunPassed', 'Failed', 'ValidationFailed')
                   AND CompletedAt__c = LAST_N_DAYS:1)
            ORDER BY StartedAt__c DESC NULLS LAST
            LIMIT 50
        ];
    }

    @AuraEnabled
    public static Id createJob(String jobName, Boolean isDryRun) {
        return MigrationJobService.createJob(jobName, isDryRun);
    }

    @AuraEnabled
    public static Id addObjectConfig(
        Id jobId, String targetObjectApiName, Integer loadOrder, String externalIdField
    ) {
        return MigrationJobService.addObjectConfig(jobId, targetObjectApiName, loadOrder, externalIdField);
    }

    @AuraEnabled
    public static Id addFieldMapping(
        Id configId, String sourceFieldName, String targetFieldApiName,
        Boolean isRelationship, String relatedObjectApiName
    ) {
        return MigrationJobService.addFieldMapping(
            configId, sourceFieldName, targetFieldApiName, isRelationship, relatedObjectApiName);
    }

    @AuraEnabled
    public static void startJob(Id jobId) {
        MigrationJobService.startJob(jobId);
    }

    @AuraEnabled
    public static void cancelJob(Id jobId) {
        MigrationJobService.cancelJob(jobId);
    }

    @AuraEnabled
    public static Id startRollback(Id jobId) {
        return MigrationJobService.startRollback(jobId);
    }
}
