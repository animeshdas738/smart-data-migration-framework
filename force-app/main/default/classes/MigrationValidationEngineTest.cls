@IsTest
private class MigrationValidationEngineTest {

    @TestSetup
    static void setup() {
        MigrationJob__c job = MigrationTestDataFactory.createJob(false);
        MigrationObjectConfig__c cfg = MigrationTestDataFactory.createConfig(job.Id, 'Account', 1);
        MigrationTestDataFactory.createMapping(cfg.Id, 'Name', 'Name', false, null);
        MigrationTestDataFactory.createMapping(cfg.Id, 'AnnualRevenue', 'AnnualRevenue', false, null);
        MigrationTestDataFactory.createMapping(cfg.Id, 'Industry', 'Industry', false, null);
        MigrationTestDataFactory.createMapping(cfg.Id, 'IsDeleted', 'IsDeleted__c', false, null);
    }

    static MigrationBatch__c getBatch() {
        MigrationJob__c job = [SELECT Id FROM MigrationJob__c LIMIT 1];
        MigrationObjectConfig__c cfg = [SELECT Id FROM MigrationObjectConfig__c LIMIT 1];
        return MigrationTestDataFactory.createBatch(job.Id, cfg.Id, 1, '[]', 'Pending');
    }

    @IsTest
    static void validRow_noErrors() {
        MigrationBatch__c batch = getBatch();
        MigrationObjectConfig__c cfg = [SELECT Id, ObjectApiName__c, LoadOrder__c FROM MigrationObjectConfig__c LIMIT 1];
        List<MigrationFieldMapping__c> maps = [
            SELECT SourceFieldName__c, TargetFieldApiName__c, IsRequired__c,
                   IsParentLookup__c, ParentObjectApiName__c
            FROM MigrationFieldMapping__c WHERE MigrationObjectConfig__c = :cfg.Id
        ];

        List<Map<String,Object>> rows = new List<Map<String,Object>>{
            new Map<String,Object>{ 'Name' => 'Acme', 'AnnualRevenue' => '5000000', 'Industry' => 'Technology' }
        };

        Test.startTest();
        MigrationValidationEngine engine = new MigrationValidationEngine();
        MigrationValidationEngine.ValidationResult result = engine.validateBatch(rows, cfg, maps, batch);
        Test.stopTest();

        System.assertEquals(true, result.passed, 'Valid row should pass');
        System.assertEquals(0, result.errorCount);
    }

    @IsTest
    static void unknownObject_generatesError() {
        MigrationJob__c job = [SELECT Id FROM MigrationJob__c LIMIT 1];
        MigrationObjectConfig__c badCfg = new MigrationObjectConfig__c(
            MigrationJob__c = job.Id, ObjectApiName__c = 'NonExistentObject__c',
            LoadOrder__c = 2, IsActive__c = true);
        insert badCfg;

        MigrationBatch__c batch = MigrationTestDataFactory.createBatch(job.Id, badCfg.Id, 2, '[]', 'Pending');

        Test.startTest();
        MigrationValidationEngine.ValidationResult result =
            new MigrationValidationEngine().validateBatch(
                new List<Map<String,Object>>(), badCfg, new List<MigrationFieldMapping__c>(), batch);
        Test.stopTest();

        System.assertEquals(false, result.passed);
        System.assertEquals(1, result.errorCount);
        System.assert(result.errors[0].ErrorMessage__c.contains('not found in schema'));
    }

    @IsTest
    static void typeMismatch_generatesError() {
        MigrationBatch__c batch = getBatch();
        MigrationObjectConfig__c cfg = [SELECT Id, ObjectApiName__c, LoadOrder__c FROM MigrationObjectConfig__c LIMIT 1];
        List<MigrationFieldMapping__c> maps = [
            SELECT SourceFieldName__c, TargetFieldApiName__c, IsRequired__c,
                   IsParentLookup__c, ParentObjectApiName__c
            FROM MigrationFieldMapping__c WHERE MigrationObjectConfig__c = :cfg.Id
        ];

        List<Map<String,Object>> rows = new List<Map<String,Object>>{
            new Map<String,Object>{ 'Name' => 'Acme', 'AnnualRevenue' => 'not-a-number' }
        };

        Test.startTest();
        MigrationValidationEngine.ValidationResult result =
            new MigrationValidationEngine().validateBatch(rows, cfg, maps, batch);
        Test.stopTest();

        System.assertEquals(false, result.passed);
        System.assert(result.errorCount > 0);
    }
}
