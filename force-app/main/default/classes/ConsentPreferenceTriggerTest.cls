/**
 * Tests for the Consent_Preference__c trigger.
 *
 * The interesting assertions are about what does NOT happen: the recursion guard, the bypass,
 * and the rule that Last_Changed__c only moves when the consent value actually moves.
 */
@IsTest
private class ConsentPreferenceTriggerTest {

    @IsTest
    static void beforeInsert_stampsTheExternalKey() {
        Contact contact = TestDataFactory.createContacts(1)[0];
        Consent_Preference__c pref = new Consent_Preference__c(
            Contact__c = contact.Id,
            Channel__c = 'Email',
            Opt_In__c = true
        );

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        insert pref;
        Test.stopTest();

        Consent_Preference__c saved = [SELECT External_Key__c FROM Consent_Preference__c WHERE Id = :pref.Id];
        Assert.areEqual(
            contact.Id + '-Email',
            saved.External_Key__c,
            'The trigger must build the composite key so every inbound integration matches on the same format.'
        );
    }

    @IsTest
    static void beforeInsert_doesNotOverwriteASuppliedExternalKey() {
        Contact contact = TestDataFactory.createContacts(1)[0];
        Consent_Preference__c pref = new Consent_Preference__c(
            Contact__c = contact.Id,
            Channel__c = 'SMS',
            Opt_In__c = true,
            External_Key__c = 'LEGACY-KEY-001'
        );

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        insert pref;
        Test.stopTest();

        Assert.areEqual(
            'LEGACY-KEY-001',
            [SELECT External_Key__c FROM Consent_Preference__c WHERE Id = :pref.Id].External_Key__c,
            'A key supplied by a migration must be preserved.'
        );
    }

    @IsTest
    static void beforeInsert_defaultsAuditFields() {
        Contact contact = TestDataFactory.createContacts(1)[0];
        Consent_Preference__c pref = new Consent_Preference__c(
            Contact__c = contact.Id, Channel__c = 'Push', Opt_In__c = true
        );

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        insert pref;
        Test.stopTest();

        Consent_Preference__c saved = [
            SELECT Last_Changed__c, Consent_Source__c, Sync_Attempts__c
            FROM Consent_Preference__c WHERE Id = :pref.Id
        ];
        Assert.isNotNull(saved.Last_Changed__c, 'Last changed should be stamped on insert.');
        Assert.areEqual('Unspecified', saved.Consent_Source__c, 'A blank source should be defaulted, not left null.');
        Assert.areEqual(0, saved.Sync_Attempts__c, 'The attempt counter should start at zero.');
    }

    @IsTest
    static void beforeUpdate_leavesLastChangedAloneWhenConsentDidNotChange() {
        Contact contact = TestDataFactory.createContacts(1)[0];
        Consent_Preference__c pref = TestDataFactory.buildPreference(contact.Id, 'Email', true);

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        insert pref;
        Datetime original = [SELECT Last_Changed__c FROM Consent_Preference__c WHERE Id = :pref.Id].Last_Changed__c;

        // Touch an unrelated field.
        update new Consent_Preference__c(Id = pref.Id, Lifecycle_Stage__c = 'Engaged');
        Test.stopTest();

        Assert.areEqual(
            original,
            [SELECT Last_Changed__c FROM Consent_Preference__c WHERE Id = :pref.Id].Last_Changed__c,
            'Last changed answers "when did they change their mind" and must not move on an unrelated edit.'
        );
    }

    @IsTest
    static void afterUpdate_doesNotRequeueWhenOnlySyncStatusChanged() {
        Contact contact = TestDataFactory.createContacts(1)[0];
        Consent_Preference__c pref = TestDataFactory.buildPreference(contact.Id, 'Email', true);

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        insert pref;

        Integer afterInsert = Limits.getQueueableJobs();
        // Exactly what the sync job itself writes back — this must not loop.
        update new Consent_Preference__c(Id = pref.Id, Sync_Status__c = 'Synced', Sync_Attempts__c = 1);
        Integer afterStatusWriteback = Limits.getQueueableJobs();
        Test.stopTest();

        Assert.areEqual(
            afterInsert,
            afterStatusWriteback,
            'The sync job writing its own status back must not enqueue another sync, or the org loops until the async limit.'
        );
    }

    @IsTest
    static void afterUpdate_requeuesWhenConsentChanges() {
        Contact contact = TestDataFactory.createContacts(1)[0];
        Consent_Preference__c pref = TestDataFactory.buildPreference(contact.Id, 'Email', true);

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        insert pref;
        Integer afterInsert = Limits.getQueueableJobs();
        update new Consent_Preference__c(Id = pref.Id, Opt_In__c = false);
        Integer afterConsentChange = Limits.getQueueableJobs();
        Test.stopTest();

        Assert.areEqual(
            afterInsert + 1,
            afterConsentChange,
            'A genuine consent change must queue a Marketing Cloud push.'
        );
    }

    @IsTest
    static void bypass_suppressesTheSyncForBulkLoads() {
        Contact contact = TestDataFactory.createContacts(1)[0];

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        ConsentPreferenceTriggerHandler.bypass = true;
        try {
            insert TestDataFactory.buildPreference(contact.Id, 'Email', true);
        } finally {
            ConsentPreferenceTriggerHandler.bypass = false;
        }
        Integer queued = Limits.getQueueableJobs();
        Test.stopTest();

        Assert.areEqual(0, queued, 'A bypassed load must not enqueue per-record syncs.');
    }

    @IsTest
    static void trigger_isBulkSafeAcrossTwoHundredRecords() {
        List<Contact> contacts = TestDataFactory.createContacts(50);
        List<Consent_Preference__c> prefs = new List<Consent_Preference__c>();
        for (Contact contact : contacts) {
            for (String channel : TestDataFactory.CHANNELS) {
                prefs.add(TestDataFactory.buildPreference(contact.Id, channel, true));
            }
        }

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        insert prefs;
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(200, prefs.size(), 'Precondition: this is a full 200-record batch.');
        Assert.isTrue(
            queriesUsed <= 2,
            'A 200-record insert must not scale its query count with the batch size. Used: ' + queriesUsed
        );
        Assert.areEqual(
            200,
            [SELECT COUNT() FROM Consent_Preference__c WHERE External_Key__c != null],
            'Every record in the batch should have been stamped.'
        );
    }
}
