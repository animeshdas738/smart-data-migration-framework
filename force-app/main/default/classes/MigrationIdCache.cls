/**
 * Platform Cache abstraction for parent ID translation maps.
 * Key pattern: {jobId}_{objectApiName} → Map<String,Id> (legacyId → sfId)
 * Falls back to chunked SOQL when Platform Cache is unavailable or disabled.
 */
public with sharing class MigrationIdCache {

    private static final String PARTITION = 'local.MigrationCache';
    private static final Integer CACHE_TTL_SECONDS = 86400; // 24 h

    // ─── Write ────────────────────────────────────────────────────────────────

    public static void put(String jobId, String objectApiName, Map<String, Id> legacyToSfId) {
        if (!isPlatformCacheEnabled()) {
            return;
        }
        try {
            Cache.Org.put(buildKey(jobId, objectApiName), legacyToSfId, CACHE_TTL_SECONDS);
        } catch (Exception ex) {
            // Non-fatal: child batches will fall back to SOQL
            System.debug(LoggingLevel.WARN, 'MigrationIdCache.put failed: ' + ex.getMessage());
        }
    }

    // ─── Read ─────────────────────────────────────────────────────────────────

    /**
     * Returns the ID map for the given parent object.
     * On cache miss: queries MigrationRecordLog__c and re-populates the cache.
     */
    public static Map<String, Id> get(String jobId, String objectApiName) {
        if (isPlatformCacheEnabled()) {
            Map<String, Id> cached = (Map<String, Id>) Cache.Org.get(buildKey(jobId, objectApiName));
            if (cached != null) {
                return cached;
            }
        }
        return loadFromSoql(jobId, objectApiName);
    }

    public static void remove(String jobId, String objectApiName) {
        if (!isPlatformCacheEnabled()) {
            return;
        }
        try {
            Cache.Org.remove(buildKey(jobId, objectApiName));
        } catch (Exception ex) {
            System.debug(LoggingLevel.WARN, 'MigrationIdCache.remove failed: ' + ex.getMessage());
        }
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    private static String buildKey(String jobId, String objectApiName) {
        // Cache key must be alphanumeric; strip the Salesforce Id dashes and dots
        return jobId.replaceAll('[^a-zA-Z0-9]', '') + '_' + objectApiName.replaceAll('[^a-zA-Z0-9]', '');
    }

    private static Map<String, Id> loadFromSoql(String jobId, String objectApiName) {
        Map<String, Id> result = new Map<String, Id>();
        // Chunked in batches of 10,000 to stay within SOQL row limits
        Integer offset = 0;
        final Integer CHUNK = 10000;
        while (true) {
            List<MigrationRecordLog__c> rows = [
                SELECT LegacyId__c, SalesforceId__c
                FROM MigrationRecordLog__c
                WHERE MigrationJob__c = :jobId
                  AND ObjectApiName__c = :objectApiName
                  AND SalesforceId__c != null
                ORDER BY Id
                LIMIT :CHUNK
                OFFSET :offset
            ];
            for (MigrationRecordLog__c r : rows) {
                result.put(r.LegacyId__c, (Id) r.SalesforceId__c);
            }
            if (rows.size() < CHUNK) {
                break;
            }
            offset += CHUNK;
        }
        put(jobId, objectApiName, result);
        return result;
    }

    private static Boolean isPlatformCacheEnabled() {
        List<MigrationFrameworkConfig__mdt> configs = [
            SELECT EnablePlatformCache__c
            FROM MigrationFrameworkConfig__mdt
            LIMIT 1
        ];
        return (!configs.isEmpty() && configs[0].EnablePlatformCache__c);
    }
}
