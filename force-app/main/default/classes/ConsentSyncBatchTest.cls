/**
 * Tests for the nightly backfill.
 *
 * The batch is scoped to SfmcClient.MAX_ROWS_PER_REQUEST so each execute() maps to exactly one
 * callout; these tests pin that relationship as well as the partial-success behaviour.
 */
@IsTest
private class ConsentSyncBatchTest {

    @IsTest
    static void batch_syncsEveryPendingRow() {
        List<Contact> contacts = TestDataFactory.createContacts(5);
        TestDataFactory.createPreferencesForAllChannels(contacts, true);

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        Database.executeBatch(new ConsentSyncBatch(), SfmcClient.MAX_ROWS_PER_REQUEST);
        Test.stopTest();

        Assert.areEqual(
            0,
            [SELECT COUNT() FROM Consent_Preference__c WHERE Sync_Status__c != 'Synced'],
            'Every pending row should have been delivered.'
        );
        Assert.areEqual(20, [SELECT COUNT() FROM Sync_Log__c], 'One log row per preference.');
    }

    @IsTest
    static void batch_skipsRowsThatExhaustedTheirAttempts() {
        List<Contact> contacts = TestDataFactory.createContacts(1);
        List<Consent_Preference__c> prefs = TestDataFactory.createPreferencesForAllChannels(contacts, true);
        prefs[0].Sync_Attempts__c = SfmcSyncQueueable.MAX_ATTEMPTS;
        prefs[0].Sync_Status__c = 'Failed';
        update prefs[0];

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        Database.executeBatch(new ConsentSyncBatch(), SfmcClient.MAX_ROWS_PER_REQUEST);
        Test.stopTest();

        Consent_Preference__c exhausted = [SELECT Sync_Status__c FROM Consent_Preference__c WHERE Id = :prefs[0].Id];
        Assert.areEqual(
            'Failed',
            exhausted.Sync_Status__c,
            'A row past the attempt ceiling must be left alone for a human rather than retried forever.'
        );
    }

    @IsTest
    static void batch_recordsFailuresWithoutHaltingTheRun() {
        List<Contact> contacts = TestDataFactory.createContacts(2);
        TestDataFactory.createPreferencesForAllChannels(contacts, true);

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.serverError());
        Test.startTest();
        Database.executeBatch(new ConsentSyncBatch(), SfmcClient.MAX_ROWS_PER_REQUEST);
        Test.stopTest();

        Assert.areEqual(
            8,
            [SELECT COUNT() FROM Consent_Preference__c WHERE Sync_Status__c = 'Failed'],
            'A failing tenant should mark rows Failed, not throw.'
        );
        for (Sync_Log__c log : [SELECT Error_Message__c, Attempt__c FROM Sync_Log__c]) {
            Assert.isNotNull(log.Error_Message__c, 'The failure reason must be captured for the console.');
            Assert.areEqual(1, log.Attempt__c, 'The attempt counter should increment from zero.');
        }
    }

    @IsTest
    static void batch_scheduleEntryPointRuns() {
        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        String jobId = System.schedule('Consent sync test', '0 0 2 * * ?', new ConsentSyncBatch());
        Test.stopTest();

        CronTrigger trigger = [SELECT CronExpression, TimesTriggered FROM CronTrigger WHERE Id = :jobId];
        Assert.areEqual('0 0 2 * * ?', trigger.CronExpression, 'The schedulable should register with the supplied cron.');
        Assert.areEqual(0, trigger.TimesTriggered, 'The job should be scheduled but not yet fired.');
    }
}
