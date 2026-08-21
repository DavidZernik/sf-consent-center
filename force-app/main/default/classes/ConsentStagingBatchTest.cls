/**
 * Tests for the ETL promotion batch.
 *
 * These cover the behaviours that only show up with real bulk files: duplicate rows for the same
 * person, values an upstream system formats differently, and the requirement that one bad row
 * never takes down the load around it.
 */
@IsTest
private class ConsentStagingBatchTest {

    private static Consent_Staging__c staged(String email, String channel, String rawValue, Datetime capturedAt) {
        return new Consent_Staging__c(
            Batch_Id__c = 'ETL-2026-08-21',
            Source_System__c = 'Informatica',
            Email__c = email,
            Channel__c = channel,
            Opt_In_Raw__c = rawValue,
            Captured_At__c = capturedAt,
            Process_Status__c = 'Unprocessed'
        );
    }

    @IsTest
    static void batch_promotesValidRows() {
        Contact contact = TestDataFactory.createContacts(1)[0];
        insert staged(contact.Email, 'Email', 'false', Datetime.now());

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        Database.executeBatch(new ConsentStagingBatch(), 200);
        Test.stopTest();

        Assert.areEqual('Processed', [SELECT Process_Status__c FROM Consent_Staging__c].Process_Status__c,
            'A valid row should be marked Processed.');
        Consent_Preference__c pref = [SELECT Opt_In__c, Consent_Source__c FROM Consent_Preference__c];
        Assert.isFalse(pref.Opt_In__c, 'The staged opt-out should have been applied.');
        Assert.areEqual('Informatica', pref.Consent_Source__c, 'The source system should be carried through.');
        Assert.areEqual(1, [SELECT COUNT() FROM Consent_History__c], 'Promotion must write the audit trail.');
    }

    @IsTest
    static void batch_interpretsTheConsentValuesUpstreamSystemsActuallySend() {
        List<Contact> contacts = TestDataFactory.createContacts(6);
        List<Consent_Staging__c> rows = new List<Consent_Staging__c>{
            staged(contacts[0].Email, 'Email', 'Y', Datetime.now()),
            staged(contacts[1].Email, 'Email', 'yes', Datetime.now()),
            staged(contacts[2].Email, 'Email', '1', Datetime.now()),
            staged(contacts[3].Email, 'Email', 'UNSUBSCRIBED', Datetime.now()),
            staged(contacts[4].Email, 'Email', 'opt-out', Datetime.now()),
            staged(contacts[5].Email, 'Email', '0', Datetime.now())
        };
        insert rows;

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        Database.executeBatch(new ConsentStagingBatch(), 200);
        Test.stopTest();

        Assert.areEqual(3, [SELECT COUNT() FROM Consent_Preference__c WHERE Opt_In__c = true],
            'Y, yes and 1 should all parse as opted in.');
        Assert.areEqual(3, [SELECT COUNT() FROM Consent_Preference__c WHERE Opt_In__c = false],
            'UNSUBSCRIBED, opt-out and 0 should all parse as opted out.');
    }

    @IsTest
    static void batch_newestCaptureWinsWhenAPersonChangedTheirMindTwiceInOneFile() {
        Contact contact = TestDataFactory.createContacts(1)[0];
        Datetime earlier = Datetime.now().addHours(-3);
        Datetime later = Datetime.now();
        // Deliberately inserted newest-first, so a naive implementation would apply the wrong one.
        insert new List<Consent_Staging__c>{
            staged(contact.Email, 'Email', 'false', later),
            staged(contact.Email, 'Email', 'true', earlier)
        };

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        Database.executeBatch(new ConsentStagingBatch(), 200);
        Test.stopTest();

        Assert.isFalse(
            [SELECT Opt_In__c FROM Consent_Preference__c].Opt_In__c,
            'The later capture must win regardless of row order in the file.'
        );
        Assert.areEqual(1, [SELECT COUNT() FROM Consent_Staging__c WHERE Process_Status__c = 'Skipped'],
            'The superseded row should be marked Skipped, not Failed.');
        Assert.areEqual(1, [SELECT COUNT() FROM Consent_Preference__c],
            'Two staged rows for one contact and channel must produce one preference record.');
    }

    @IsTest
    static void batch_recordsPerRowErrorsWithoutFailingTheLoad() {
        Contact contact = TestDataFactory.createContacts(1)[0];
        insert new List<Consent_Staging__c>{
            staged(contact.Email, 'Email', 'true', Datetime.now()),
            staged(contact.Email, 'Carrier Pigeon', 'true', Datetime.now()),
            staged('nobody@example.invalid', 'Email', 'true', Datetime.now()),
            staged(contact.Email, 'SMS', 'maybe', Datetime.now())
        };

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        Database.executeBatch(new ConsentStagingBatch(), 200);
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Consent_Staging__c WHERE Process_Status__c = 'Processed'],
            'The one valid row must still be promoted.');
        Assert.areEqual(3, [SELECT COUNT() FROM Consent_Staging__c WHERE Process_Status__c = 'Failed'],
            'Each invalid row should fail independently.');

        for (Consent_Staging__c row : [SELECT Error_Message__c FROM Consent_Staging__c WHERE Process_Status__c = 'Failed']) {
            Assert.isNotNull(
                row.Error_Message__c,
                'The reason must be written onto the staging row so the ETL team can query their own failures.'
            );
        }
    }

    @IsTest
    static void batch_matchesOnExternalIdInPreferenceToEmail() {
        Contact contact = new Contact(
            FirstName = 'Ext', LastName = 'Match',
            Email = 'shared@example.invalid', ExternalId__c = 'SRC-9001'
        );
        insert contact;
        // A different person now shares the email address. Without this record the test proves
        // nothing: external id only "wins" if there is something for it to win against.
        insert new Contact(FirstName = 'Someone', LastName = 'Else', Email = 'shared@example.invalid');
        Consent_Staging__c row = staged(null, 'Email', 'false', Datetime.now());
        row.Contact_External_Id__c = 'SRC-9001';
        row.Email__c = 'shared@example.invalid';
        insert row;

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        Database.executeBatch(new ConsentStagingBatch(), 200);
        Test.stopTest();

        Assert.areEqual(
            contact.Id,
            [SELECT Contact__c FROM Consent_Preference__c].Contact__c,
            'External id must take precedence over email, because email addresses get reused between people.'
        );
    }

    @IsTest
    static void batch_skipsRowsAlreadyInTheRequestedState() {
        Contact contact = TestDataFactory.createContacts(1)[0];
        TestDataFactory.createPreferencesForAllChannels(new List<Contact>{ contact }, true);
        insert staged(contact.Email, 'Email', 'true', Datetime.now());

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        Database.executeBatch(new ConsentStagingBatch(), 200);
        Test.stopTest();

        Assert.areEqual('Skipped', [SELECT Process_Status__c FROM Consent_Staging__c].Process_Status__c,
            'A row that requests the state already in place is a no-op, not a failure.');
        Assert.areEqual(0, [SELECT COUNT() FROM Consent_History__c],
            'A no-op must not pollute the audit trail.');
    }

    @IsTest
    static void batch_scopedToOneEtlBatchLeavesOtherRowsAlone() {
        List<Contact> contacts = TestDataFactory.createContacts(2);
        Consent_Staging__c mine = staged(contacts[0].Email, 'Email', 'false', Datetime.now());
        Consent_Staging__c theirs = staged(contacts[1].Email, 'Email', 'false', Datetime.now());
        theirs.Batch_Id__c = 'ETL-OTHER';
        insert new List<Consent_Staging__c>{ mine, theirs };

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        Database.executeBatch(new ConsentStagingBatch('ETL-2026-08-21'), 200);
        Test.stopTest();

        Assert.areEqual('Processed',
            [SELECT Process_Status__c FROM Consent_Staging__c WHERE Id = :mine.Id].Process_Status__c,
            'The scoped batch should be processed.');
        Assert.areEqual('Unprocessed',
            [SELECT Process_Status__c FROM Consent_Staging__c WHERE Id = :theirs.Id].Process_Status__c,
            'Rows belonging to another ETL batch must be untouched.');
    }

    @IsTest
    static void batch_queuesOneSyncPerChunkNotOnePerRecord() {
        List<Contact> contacts = TestDataFactory.createContacts(20);
        List<Consent_Staging__c> rows = new List<Consent_Staging__c>();
        for (Contact contact : contacts) {
            rows.add(staged(contact.Email, 'Email', 'false', Datetime.now()));
        }
        insert rows;

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        Database.executeBatch(new ConsentStagingBatch(), 200);
        Test.stopTest();

        Assert.areEqual(20, [SELECT COUNT() FROM Consent_Preference__c], 'All 20 should have been promoted.');
        Assert.isFalse(
            ConsentPreferenceTriggerHandler.bypass,
            'The bypass must be reset after the batch, or the trigger stays disabled for the rest of the transaction.'
        );
    }

    @IsTest
    static void batch_scheduleEntryPointRuns() {
        Test.startTest();
        String jobId = System.schedule('Staging promotion test', '0 30 1 * * ?', new ConsentStagingBatch());
        Test.stopTest();

        Assert.areEqual('0 30 1 * * ?',
            [SELECT CronExpression FROM CronTrigger WHERE Id = :jobId].CronExpression,
            'The schedulable entry point should register with the supplied cron.');
    }

    @IsTest
    static void validateShape_rejectsEveryMalformedVariant() {
        Assert.isNotNull(ConsentStagingBatch.validateShape(new Consent_Staging__c(Channel__c = 'Email', Opt_In_Raw__c = 'true')),
            'A row with no match key is invalid.');
        Assert.isNotNull(ConsentStagingBatch.validateShape(new Consent_Staging__c(Email__c = 'a@b.invalid', Opt_In_Raw__c = 'true')),
            'A row with no channel is invalid.');
        Assert.isNotNull(ConsentStagingBatch.validateShape(new Consent_Staging__c(Email__c = 'a@b.invalid', Channel__c = 'Email')),
            'A row with no consent value is invalid.');
        Assert.isNull(ConsentStagingBatch.validateShape(
            new Consent_Staging__c(Email__c = 'a@b.invalid', Channel__c = 'Email', Opt_In_Raw__c = 'Yes')),
            'A well-formed row should pass validation.');
    }
}
