/**
 * Behavioural tests for the service boundary.
 *
 * These assert outcomes the UI depends on (the audit trail, the no-op skip, the rollback)
 * rather than simply executing lines for coverage.
 */
@IsTest
private class ConsentServiceTest {

    @TestSetup
    static void setup() {
        List<Contact> contacts = TestDataFactory.createContacts(5);
        TestDataFactory.createPreferencesForAllChannels(contacts, true);
    }

    @IsTest
    static void getConsentSummaries_returnsEveryChannelPerContact() {
        Test.startTest();
        List<ConsentService.ConsentSummary> summaries = ConsentService.getConsentSummaries(null, null);
        Test.stopTest();

        Assert.areEqual(20, summaries.size(), '5 contacts x 4 channels should all be returned.');
        Set<String> channels = new Set<String>();
        for (ConsentService.ConsentSummary s : summaries) {
            channels.add(s.channel);
            Assert.isNotNull(s.contactName, 'Contact name must be populated for the datatable.');
            Assert.isTrue(s.optIn, 'Fixture data is opted in.');
        }
        Assert.areEqual(4, channels.size(), 'All four channels should be represented.');
    }

    @IsTest
    static void getConsentSummaries_filtersByChannel() {
        Test.startTest();
        List<ConsentService.ConsentSummary> summaries = ConsentService.getConsentSummaries(null, 'SMS');
        Test.stopTest();

        Assert.areEqual(5, summaries.size(), 'Only the SMS row per contact should match.');
        for (ConsentService.ConsentSummary s : summaries) {
            Assert.areEqual('SMS', s.channel, 'Channel filter leaked a different channel.');
        }
    }

    @IsTest
    static void getConsentSummaries_searchTermWithWildcardCharacterIsEscaped() {
        // A raw % in the search term must be treated as a literal, not as a wildcard that
        // silently widens the result set.
        Test.startTest();
        List<ConsentService.ConsentSummary> summaries = ConsentService.getConsentSummaries('%', null);
        Test.stopTest();

        Assert.areEqual(0, summaries.size(), 'A literal percent sign should match no contact name.');
    }

    @IsTest
    static void getConsentSummaries_staysBulkSafeAcrossManyRecords() {
        // 60 contacts x 4 channels = 240 preference rows, above the selector row cap.
        List<Contact> extra = TestDataFactory.createContacts(60);
        TestDataFactory.createPreferencesForAllChannels(extra, false);

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        List<ConsentService.ConsentSummary> summaries = ConsentService.getConsentSummaries(null, null);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(1, queriesUsed, 'Building summaries must cost exactly one SOQL query.');
        Assert.areEqual(
            ConsentSelector.DEFAULT_MAX_ROWS,
            summaries.size(),
            'The selector row ceiling should cap the result set rather than the governor limit.'
        );
    }

    @IsTest
    static void getConsentDetail_returnsPreferencesAndHistory() {
        Contact c = [SELECT Id FROM Contact LIMIT 1];

        Test.startTest();
        ConsentService.ConsentDetail detail = ConsentService.getConsentDetail(c.Id);
        Test.stopTest();

        Assert.areEqual(c.Id, detail.contactId, 'Detail should echo the requested contact.');
        Assert.areEqual(4, detail.preferences.size(), 'Every channel should be present.');
        Assert.areEqual(0, detail.history.size(), 'No changes have been made yet.');
        Assert.isNotNull(detail.email, 'Email is needed for the Data Extension payload.');
    }

    @IsTest
    static void getConsentDetail_nullContactIsRejected() {
        try {
            ConsentService.getConsentDetail(null);
            Assert.fail('A null contact id should not be accepted.');
        } catch (AuraHandledException e) {
            Assert.areEqual('A contact is required.', e.getMessage(), 'The UI needs the real reason, not a generic script error.');
        }
    }

    @IsTest
    static void savePreferences_writesAuditTrailAndQueuesSync() {
        Contact c = [SELECT Id FROM Contact LIMIT 1];
        String changes = TestDataFactory.changesJson(new Map<String, Boolean>{ 'Email' => false, 'SMS' => false });

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        ConsentService.ConsentDetail detail = ConsentService.savePreferences(c.Id, changes, 'Preference Centre');
        Integer queuedJobs = Limits.getQueueableJobs();
        Test.stopTest();

        Assert.areEqual(1, queuedJobs, 'Two changed rows fit in a single chunk, so one job should be queued.');

        for (ConsentService.ChannelPreference p : detail.preferences) {
            if (p.channel == 'Email' || p.channel == 'SMS') {
                Assert.isFalse(p.optIn, p.channel + ' should now be opted out.');
            } else {
                Assert.isTrue(p.optIn, p.channel + ' was untouched and should stay opted in.');
            }
        }

        List<Consent_History__c> history = [
            SELECT Channel__c, Previous_Value__c, New_Value__c, Change_Source__c
            FROM Consent_History__c
            WHERE Contact__c = :c.Id
        ];
        Assert.areEqual(2, history.size(), 'Exactly the two changed channels should be audited.');
        for (Consent_History__c h : history) {
            Assert.areEqual('Opted In', h.Previous_Value__c, 'Previous value should reflect the fixture state.');
            Assert.areEqual('Opted Out', h.New_Value__c, 'New value should reflect the requested change.');
            Assert.areEqual('Preference Centre', h.Change_Source__c, 'Source should be carried through to the audit row.');
        }
    }

    @IsTest
    static void savePreferences_ignoresNoOpChanges() {
        Contact c = [SELECT Id FROM Contact LIMIT 1];
        // Fixture is already opted in on Email; re-submitting the same value is not a change.
        String changes = TestDataFactory.changesJson(new Map<String, Boolean>{ 'Email' => true });

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        ConsentService.savePreferences(c.Id, changes, 'Preference Centre');
        Integer queuedJobs = Limits.getQueueableJobs();
        Test.stopTest();

        Assert.areEqual(0, queuedJobs, 'A no-op save must not queue a Marketing Cloud push.');
        Assert.areEqual(
            0,
            [SELECT COUNT() FROM Consent_History__c WHERE Contact__c = :c.Id],
            'A no-op save must not pollute the audit trail.'
        );
    }

    @IsTest
    static void savePreferences_createsPreferenceWhenChannelIsNew() {
        Contact c = TestDataFactory.createContacts(1)[0];
        String changes = TestDataFactory.changesJson(new Map<String, Boolean>{ 'Push' => true });

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        ConsentService.ConsentDetail detail = ConsentService.savePreferences(c.Id, changes, 'Mobile App');
        Test.stopTest();

        Assert.areEqual(1, detail.preferences.size(), 'A preference row should have been created.');
        Assert.areEqual('Push', detail.preferences[0].channel, 'The new row should be on the requested channel.');

        Consent_History__c audit = [SELECT Previous_Value__c FROM Consent_History__c WHERE Contact__c = :c.Id];
        Assert.areEqual('None', audit.Previous_Value__c, 'First-ever consent should record None as the previous value.');
    }

    @IsTest
    static void savePreferences_rejectsUnsupportedChannelAndRollsBack() {
        Contact c = [SELECT Id FROM Contact LIMIT 1];
        String changes = TestDataFactory.changesJson(new Map<String, Boolean>{ 'Carrier Pigeon' => true });

        Test.startTest();
        try {
            ConsentService.savePreferences(c.Id, changes, 'Preference Centre');
            Assert.fail('An unsupported channel should be rejected.');
        } catch (AuraHandledException e) {
            Assert.isTrue(
                e.getMessage().contains('Carrier Pigeon'),
                'The error should name the offending channel. Got: ' + e.getMessage()
            );
        }
        Test.stopTest();

        Assert.areEqual(
            0,
            [SELECT COUNT() FROM Consent_History__c WHERE Contact__c = :c.Id],
            'A rejected save must leave no partial audit rows behind.'
        );
    }

    @IsTest
    static void savePreferences_blankPayloadIsRejected() {
        Contact c = [SELECT Id FROM Contact LIMIT 1];
        try {
            ConsentService.savePreferences(c.Id, '', 'Preference Centre');
            Assert.fail('A blank payload should be rejected before any DML.');
        } catch (AuraHandledException e) {
            Assert.areEqual('No preference changes were supplied.', e.getMessage(), 'Message should be actionable.');
        }
    }

    @IsTest
    static void getSyncLogs_filtersByStatus() {
        List<Consent_Preference__c> prefs = [SELECT Id FROM Consent_Preference__c LIMIT 6];
        TestDataFactory.createSyncLogs(new List<Consent_Preference__c>{ prefs[0], prefs[1] }, 'Failed');
        TestDataFactory.createSyncLogs(new List<Consent_Preference__c>{ prefs[2] }, 'Success');

        Test.startTest();
        List<ConsentService.SyncLogView> failed = ConsentService.getSyncLogs('Failed');
        List<ConsentService.SyncLogView> all = ConsentService.getSyncLogs('All');
        Test.stopTest();

        Assert.areEqual(2, failed.size(), 'Only failed entries should come back under the Failed filter.');
        Assert.areEqual(3, all.size(), 'The All filter should not filter.');
        Assert.areEqual('Simulated failure', failed[0].errorMessage, 'Error text should surface to the console.');
    }

    @IsTest
    static void retrySync_queuesFailedRowsAndSkipsAlreadySynced() {
        List<Consent_Preference__c> prefs = [SELECT Id FROM Consent_Preference__c LIMIT 2];
        prefs[0].Sync_Status__c = 'Failed';
        prefs[1].Sync_Status__c = 'Synced';
        update prefs;
        List<Sync_Log__c> logs = TestDataFactory.createSyncLogs(prefs, 'Failed');

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        ConsentService.RetryResult result = ConsentService.retrySync(new List<Id>{ logs[0].Id, logs[1].Id });
        Test.stopTest();

        Assert.areEqual(1, result.queued, 'Only the failed preference should be queued.');
        Assert.areEqual(1, result.skipped, 'The already-synced preference should be skipped, not re-sent.');

        Consent_Preference__c reset = [SELECT Sync_Status__c, Sync_Attempts__c FROM Consent_Preference__c WHERE Id = :prefs[0].Id];
        Assert.areEqual('Synced', reset.Sync_Status__c, 'The queued job runs at stopTest and should have succeeded.');
    }

    @IsTest
    static void retrySync_emptyInputIsHandledGracefully() {
        Test.startTest();
        ConsentService.RetryResult result = ConsentService.retrySync(new List<Id>());
        Test.stopTest();

        Assert.areEqual(0, result.queued, 'Nothing to queue.');
        Assert.areEqual('Nothing selected to retry.', result.message, 'The console shows this message verbatim.');
    }
}
