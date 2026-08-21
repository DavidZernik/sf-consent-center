/**
 * Tests for the async delivery path.
 *
 * Queueable chaining is not permitted inside a test context, so the retry decision is asserted
 * through the Sync_Log__c status the job writes rather than by observing a second job run.
 */
@IsTest
private class SfmcSyncQueueableTest {

    @IsTest
    static void execute_successMarksRowsSyncedAndLogsTheAttempt() {
        List<Contact> contacts = TestDataFactory.createContacts(2);
        List<Consent_Preference__c> prefs = TestDataFactory.createPreferencesForAllChannels(contacts, true);
        List<Id> ids = new List<Id>(new Map<Id, Consent_Preference__c>(prefs).keySet());

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        System.enqueueJob(new SfmcSyncQueueable(ids));
        Test.stopTest();

        List<Consent_Preference__c> after = [SELECT Sync_Status__c, Sync_Attempts__c, Last_Sync_Error__c FROM Consent_Preference__c];
        for (Consent_Preference__c pref : after) {
            Assert.areEqual('Synced', pref.Sync_Status__c, 'A 202 should mark the row synced.');
            Assert.areEqual(1, pref.Sync_Attempts__c, 'This was the first attempt.');
            Assert.isNull(pref.Last_Sync_Error__c, 'A successful attempt should clear any stale error.');
        }
        Assert.areEqual(8, [SELECT COUNT() FROM Sync_Log__c], 'One log row per preference per attempt.');
    }

    @IsTest
    static void execute_transientFailureMarksRowsForRetry() {
        List<Contact> contacts = TestDataFactory.createContacts(1);
        List<Consent_Preference__c> prefs = TestDataFactory.createPreferencesForAllChannels(contacts, true);
        List<Id> ids = new List<Id>(new Map<Id, Consent_Preference__c>(prefs).keySet());

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.serverError());
        Test.startTest();
        System.enqueueJob(new SfmcSyncQueueable(ids, 1));
        Test.stopTest();

        for (Consent_Preference__c pref : [SELECT Sync_Status__c, Last_Sync_Error__c FROM Consent_Preference__c]) {
            Assert.areEqual('Pending', pref.Sync_Status__c, 'A retryable failure stays Pending so the backfill picks it up.');
            Assert.isNotNull(pref.Last_Sync_Error__c, 'The failure reason should be stored on the record.');
        }
        for (Sync_Log__c log : [SELECT Status__c, Status_Code__c FROM Sync_Log__c]) {
            Assert.areEqual('Retrying', log.Status__c, 'Attempt 1 of 4 with a 5xx should be logged as Retrying.');
            Assert.areEqual(500, log.Status_Code__c, 'The upstream status belongs in the log.');
        }
    }

    @IsTest
    static void execute_permanentFailureStopsRetryingImmediately() {
        List<Contact> contacts = TestDataFactory.createContacts(1);
        List<Consent_Preference__c> prefs = TestDataFactory.createPreferencesForAllChannels(contacts, true);
        List<Id> ids = new List<Id>(new Map<Id, Consent_Preference__c>(prefs).keySet());

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.badRequest());
        Test.startTest();
        System.enqueueJob(new SfmcSyncQueueable(ids, 1));
        Test.stopTest();

        for (Consent_Preference__c pref : [SELECT Sync_Status__c FROM Consent_Preference__c]) {
            Assert.areEqual('Failed', pref.Sync_Status__c, 'A 400 is permanent, so the row parks as Failed on attempt 1.');
        }
        for (Sync_Log__c log : [SELECT Status__c FROM Sync_Log__c]) {
            Assert.areEqual('Failed', log.Status__c, 'A non-retryable failure must not be logged as Retrying.');
        }
    }

    @IsTest
    static void execute_exhaustedAttemptsParkTheRowAsFailed() {
        List<Contact> contacts = TestDataFactory.createContacts(1);
        List<Consent_Preference__c> prefs = TestDataFactory.createPreferencesForAllChannels(contacts, true);
        List<Id> ids = new List<Id>(new Map<Id, Consent_Preference__c>(prefs).keySet());

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.serverError());
        Test.startTest();
        // Final permitted attempt: even a retryable error must stop here.
        System.enqueueJob(new SfmcSyncQueueable(ids, SfmcSyncQueueable.MAX_ATTEMPTS));
        Test.stopTest();

        for (Consent_Preference__c pref : [SELECT Sync_Status__c, Sync_Attempts__c FROM Consent_Preference__c]) {
            Assert.areEqual('Failed', pref.Sync_Status__c, 'The attempt ceiling must terminate the retry loop.');
            Assert.areEqual(SfmcSyncQueueable.MAX_ATTEMPTS, pref.Sync_Attempts__c, 'The attempt counter should reflect the final attempt.');
        }
    }

    @IsTest
    static void enqueueAll_chunksToTheCalloutPayloadLimit() {
        List<Id> ids = new List<Id>();
        // 120 fake ids exercise the chunking arithmetic without 120 rows of DML.
        for (Integer i = 0; i < 120; i++) {
            ids.add(fakeId(Consent_Preference__c.SObjectType, i + 1));
        }

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        List<Id> jobIds = SfmcSyncQueueable.enqueueAll(ids);
        Test.stopTest();

        Assert.areEqual(3, jobIds.size(), '120 rows at 50 per request should produce 3 jobs.');
    }

    @IsTest
    static void enqueueAll_emptyInputQueuesNothing() {
        Test.startTest();
        Assert.areEqual(0, SfmcSyncQueueable.enqueueAll(null).size(), 'Null input should queue nothing.');
        Assert.areEqual(0, SfmcSyncQueueable.enqueueAll(new List<Id>()).size(), 'Empty input should queue nothing.');
        Assert.areEqual(0, Limits.getQueueableJobs(), 'No jobs should have been enqueued.');
        Test.stopTest();
    }

    @IsTest
    static void execute_missingRecordsExitQuietly() {
        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        // Ids that resolve to nothing — e.g. rows deleted between queueing and execution.
        System.enqueueJob(new SfmcSyncQueueable(new List<Id>{ fakeId(Consent_Preference__c.SObjectType, 999) }));
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Sync_Log__c], 'Vanished records should not produce log noise.');
    }

    /** Builds a well-formed but non-existent id, so chunking logic can be tested without DML. */
    private static Id fakeId(Schema.SObjectType sobjectType, Integer index) {
        return Id.valueOf(
            sobjectType.getDescribe().getKeyPrefix() + '0'.repeat(9) + String.valueOf(index).leftPad(6, '0')
        );
    }
}
