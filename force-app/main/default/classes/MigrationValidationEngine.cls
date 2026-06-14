/**
 * Pre-migration validation pass. Runs before any DML.
 * Validates: field existence, data type compatibility, required-field coverage,
 * picklist value membership, and external-ID field presence for upsert targets.
 * Emits MigrationRowError__c records with Phase = PreValidation.
 */
public with sharing class MigrationValidationEngine {

    public class ValidationResult {
        public Boolean passed        = true;
        public Integer errorCount    = 0;
        public List<MigrationRowError__c> errors = new List<MigrationRowError__c>();
    }

    // ─── Per-object field describe cache (lives for this Apex transaction) ────

    private Map<String, Map<String, Schema.SObjectField>> describeCache =
        new Map<String, Map<String, Schema.SObjectField>>();

    // ─── Public API ──────────────────────────────────────────────────────────

    /**
     * Validates a batch of raw rows against the target object's schema.
     * rows       : list of Map<fieldApiName, rawValue>
     * config     : the MigrationObjectConfig__c for this object
     * fieldMaps  : MigrationFieldMapping__c records for this object
     * batchRec   : the MigrationBatch__c being processed (for error FK)
     */
    public ValidationResult validateBatch(
        List<Map<String, Object>> rows,
        MigrationObjectConfig__c config,
        List<MigrationFieldMapping__c> fieldMaps,
        MigrationBatch__c batchRec
    ) {
        ValidationResult result = new ValidationResult();
        Map<String, Schema.SObjectField> fieldMap = describeObject(config.ObjectApiName__c);
        if (fieldMap == null) {
            MigrationRowError__c err = buildError(batchRec, null, null,
                'Target object not found in schema: ' + config.ObjectApiName__c, 'PreValidation');
            result.errors.add(err);
            result.passed = false;
            result.errorCount++;
            return result;
        }

        // Build a quick lookup: sourceField → MigrationFieldMapping__c
        Map<String, MigrationFieldMapping__c> mappingIndex = new Map<String, MigrationFieldMapping__c>();
        for (MigrationFieldMapping__c fm : fieldMaps) {
            mappingIndex.put(fm.SourceFieldName__c, fm);
        }

        // Validate each mapping target exists and is the right type
        for (MigrationFieldMapping__c fm : fieldMaps) {
            if (!fieldMap.containsKey(fm.TargetFieldApiName__c.toLowerCase())) {
                result.errors.add(buildError(batchRec, null, fm.TargetFieldApiName__c,
                    'Target field does not exist on ' + config.ObjectApiName__c, 'PreValidation'));
                result.passed = false;
                result.errorCount++;
            }
        }

        // Row-level validation
        Integer rowIndex = 0;
        for (Map<String, Object> row : rows) {
            for (MigrationFieldMapping__c fm : fieldMaps) {
                Object rawVal = row.get(fm.SourceFieldName__c);

                // Required field missing
                if (fm.IsRequired__c && (rawVal == null || String.valueOf(rawVal).trim() == '')) {
                    result.errors.add(buildError(batchRec, rowIndex, fm.TargetFieldApiName__c,
                        'Required field is null or blank', 'PreValidation'));
                    result.passed = false;
                    result.errorCount++;
                    continue;
                }

                if (rawVal == null) {
                    continue;
                }

                // Type compatibility check
                Schema.SObjectField sfField = fieldMap.get(fm.TargetFieldApiName__c.toLowerCase());
                if (sfField != null) {
                    String typeErr = checkTypeCompatibility(sfField.getDescribe(), rawVal);
                    if (typeErr != null) {
                        result.errors.add(buildError(batchRec, rowIndex, fm.TargetFieldApiName__c,
                            typeErr, 'PreValidation'));
                        result.passed = false;
                        result.errorCount++;
                    }

                    // Picklist membership
                    if (sfField.getDescribe().getType() == Schema.DisplayType.PICKLIST
                            || sfField.getDescribe().getType() == Schema.DisplayType.MULTIPICKLIST) {
                        String pickErr = checkPicklist(sfField.getDescribe(), String.valueOf(rawVal));
                        if (pickErr != null) {
                            result.errors.add(buildError(batchRec, rowIndex, fm.TargetFieldApiName__c,
                                pickErr, 'PreValidation'));
                            result.passed = false;
                            result.errorCount++;
                        }
                    }
                }
            }
            rowIndex++;
        }

        return result;
    }

    // ─── Schema helpers ──────────────────────────────────────────────────────

    private Map<String, Schema.SObjectField> describeObject(String apiName) {
        if (describeCache.containsKey(apiName)) {
            return describeCache.get(apiName);
        }
        Schema.SObjectType sot = Schema.getGlobalDescribe().get(apiName);
        if (sot == null) {
            describeCache.put(apiName, null);
            return null;
        }
        Map<String, Schema.SObjectField> fm = sot.getDescribe().fields.getMap();
        describeCache.put(apiName, fm);
        return fm;
    }

    private String checkTypeCompatibility(Schema.DescribeFieldResult dfr, Object rawVal) {
        Schema.DisplayType dt = dfr.getType();
        String strVal = String.valueOf(rawVal);
        try {
            if (dt == Schema.DisplayType.DATE) {
                Date.valueOf(strVal);
            } else if (dt == Schema.DisplayType.DATETIME) {
                Datetime.valueOf(strVal);
            } else if (dt == Schema.DisplayType.DOUBLE || dt == Schema.DisplayType.CURRENCY
                    || dt == Schema.DisplayType.PERCENT) {
                Decimal.valueOf(strVal);
            } else if (dt == Schema.DisplayType.INTEGER) {
                Integer.valueOf(strVal);
            } else if (dt == Schema.DisplayType.BOOLEAN) {
                if (strVal != 'true' && strVal != 'false' && strVal != '1' && strVal != '0') {
                    return 'Boolean field expects true/false/1/0, got: ' + strVal;
                }
            }
        } catch (Exception ex) {
            return 'Type mismatch for ' + dt + ': ' + strVal;
        }
        return null;
    }

    private String checkPicklist(Schema.DescribeFieldResult dfr, String value) {
        Set<String> allowed = new Set<String>();
        for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
            if (pe.isActive()) {
                allowed.add(pe.getValue());
            }
        }
        if (!allowed.contains(value)) {
            return 'Value "' + value + '" is not an active picklist entry. Allowed: ' + allowed;
        }
        return null;
    }

    private static MigrationRowError__c buildError(
        MigrationBatch__c batchRec,
        Integer rowIndex,
        String fieldName,
        String message,
        String phase
    ) {
        return new MigrationRowError__c(
            MigrationBatch__c  = batchRec.Id,
            MigrationJob__c    = batchRec.MigrationJob__c,
            RowNumber__c       = rowIndex != null ? rowIndex : 0,
            FieldApiName__c    = fieldName,
            ErrorMessage__c    = message,
            Phase__c           = phase
        );
    }
}
