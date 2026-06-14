@IsTest
private class MigrationRelationshipResolverTest {

    @IsTest
    static void topologicalSort_parentBeforeChild() {
        MigrationJob__c job = MigrationTestDataFactory.createJob(false);
        MigrationObjectConfig__c child  = MigrationTestDataFactory.createConfig(job.Id, 'Contact', 2);
        MigrationObjectConfig__c parent = MigrationTestDataFactory.createConfig(job.Id, 'Account', 1);
        insert new MigrationObjectDependency__c(
            MigrationJob__c       = job.Id,
            ParentObjectConfig__c = parent.Id,
            ChildObjectConfig__c  = child.Id
        );

        Test.startTest();
        MigrationRelationshipResolver.ResolutionResult result =
            new MigrationRelationshipResolver().resolve(job.Id);
        Test.stopTest();

        System.assertEquals(true, result.success, result.errorMessage);
        System.assertEquals(2, result.orderedApiNames.size());
        System.assertEquals('Account', result.orderedApiNames[0], 'Account must load before Contact');
        System.assertEquals('Contact', result.orderedApiNames[1]);
    }

    @IsTest
    static void selfReferentialObject_detectedNotInOrder() {
        MigrationJob__c job = MigrationTestDataFactory.createJob(false);
        MigrationObjectConfig__c cfg = MigrationTestDataFactory.createConfig(job.Id, 'Account', 1);
        insert new MigrationObjectDependency__c(
            MigrationJob__c       = job.Id,
            ParentObjectConfig__c = cfg.Id,
            ChildObjectConfig__c  = cfg.Id
        );

        Test.startTest();
        MigrationRelationshipResolver.ResolutionResult result =
            new MigrationRelationshipResolver().resolve(job.Id);
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assert(result.selfReferential.contains('Account'), 'Account should be flagged as self-referential');
    }

    @IsTest
    static void noConfigs_returnsFailure() {
        MigrationJob__c job = MigrationTestDataFactory.createJob(false);

        Test.startTest();
        MigrationRelationshipResolver.ResolutionResult result =
            new MigrationRelationshipResolver().resolve(job.Id);
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assert(result.errorMessage.contains('No active'));
    }

    @IsTest
    static void multipleObjects_sortedCorrectly() {
        MigrationJob__c job = MigrationTestDataFactory.createJob(false);
        MigrationObjectConfig__c acct = MigrationTestDataFactory.createConfig(job.Id, 'Account', 1);
        MigrationObjectConfig__c cont = MigrationTestDataFactory.createConfig(job.Id, 'Contact', 2);
        MigrationObjectConfig__c opp  = MigrationTestDataFactory.createConfig(job.Id, 'Opportunity', 3);
        insert new List<MigrationObjectDependency__c>{
            new MigrationObjectDependency__c(MigrationJob__c = job.Id,
                ParentObjectConfig__c = acct.Id, ChildObjectConfig__c = cont.Id),
            new MigrationObjectDependency__c(MigrationJob__c = job.Id,
                ParentObjectConfig__c = acct.Id, ChildObjectConfig__c = opp.Id)
        };

        Test.startTest();
        MigrationRelationshipResolver.ResolutionResult result =
            new MigrationRelationshipResolver().resolve(job.Id);
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assertEquals(3, result.orderedApiNames.size());
        System.assertEquals('Account', result.orderedApiNames[0]);
    }
}
