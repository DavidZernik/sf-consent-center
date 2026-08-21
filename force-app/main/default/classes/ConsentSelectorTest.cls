/**
 * Tests for the SOQL boundary — row caps, ordering, and the empty-input short circuit that
 * keeps callers from burning a query on nothing.
 */
@IsTest
private class ConsentSelectorTest {
    private static final ConsentSelector SELECTOR = new ConsentSelector();

    @TestSetup
    static void setup() {
        List<Contact> contacts = TestDataFactory.createContacts(3);
        TestDataFactory.createPreferencesForAllChannels(contacts, true);
    }

    @IsTest
    static void selectByContactIds_emptySetSkipsTheQuery() {
        Test.startTest();
        Integer before = Limits.getQueries();
        List<Consent_Preference__c> result = SELECTOR.selectByContactIds(new Set<Id>());
        Integer used = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(0, result.size(), 'An empty input yields an empty result.');
        Assert.areEqual(0, used, 'An empty input must not cost a SOQL query.');
    }

    @IsTest
    static void selectByContactIds_nullSetIsHandled() {
        Assert.areEqual(0, SELECTOR.selectByContactIds(null).size(), 'A null set must not throw.');
        Assert.areEqual(0, SELECTOR.selectHistoryByContactIds(null, 10).size(), 'A null set must not throw.');
    }

    @IsTest
    static void searchSummaries_matchesOnEmailAsWellAsName() {
        Test.startTest();
        List<Consent_Preference__c> byEmail = SELECTOR.searchSummaries('contact1@example.invalid', null, 50);
        Test.stopTest();

        Assert.areEqual(4, byEmail.size(), 'One contact across four channels should match on email.');
    }

    @IsTest
    static void searchSummaries_respectsTheRowCeiling() {
        Test.startTest();
        List<Consent_Preference__c> capped = SELECTOR.searchSummaries(null, null, 5);
        Test.stopTest();

        Assert.areEqual(5, capped.size(), 'An explicit maxRows should be honoured.');
    }

    @IsTest
    static void searchSummaries_cannotExceedTheHardCeiling() {
        Test.startTest();
        List<Consent_Preference__c> result = SELECTOR.searchSummaries(null, null, 10000);
        Test.stopTest();

        Assert.isTrue(
            result.size() <= ConsentSelector.DEFAULT_MAX_ROWS,
            'A caller must not be able to raise the row cap above the class default.'
        );
    }

    @IsTest
    static void selectPendingSync_returnsPendingAndFailedOnly() {
        List<Consent_Preference__c> prefs = [SELECT Id, Sync_Status__c FROM Consent_Preference__c LIMIT 3];
        prefs[0].Sync_Status__c = 'Synced';
        prefs[1].Sync_Status__c = 'Failed';
        prefs[2].Sync_Status__c = 'Pending';
        update prefs;

        Test.startTest();
        List<Consent_Preference__c> pending = SELECTOR.selectPendingSync(100);
        Test.stopTest();

        for (Consent_Preference__c pref : pending) {
            Assert.areNotEqual('Synced', pref.Sync_Status__c, 'Already-synced rows must not be picked up again.');
        }
        Assert.isTrue(pending.size() >= 2, 'The Failed and Pending rows should both be returned.');
    }

    @IsTest
    static void selectSyncLogs_defaultsToEveryStatus() {
        List<Consent_Preference__c> prefs = [SELECT Id FROM Consent_Preference__c LIMIT 2];
        TestDataFactory.createSyncLogs(prefs, 'Failed');

        Test.startTest();
        List<Sync_Log__c> all = SELECTOR.selectSyncLogs(null, 50);
        List<Sync_Log__c> successOnly = SELECTOR.selectSyncLogs('Success', 50);
        Test.stopTest();

        Assert.areEqual(2, all.size(), 'A null status filter should return everything.');
        Assert.areEqual(0, successOnly.size(), 'No successful attempts exist in this fixture.');
    }

    @IsTest
    static void searchEverywhere_spansMultipleObjectsInOneRoundTrip() {
        List<Contact> contacts = [SELECT Id FROM Contact LIMIT 1];
        Id contactId = contacts[0].Id;
        Test.setFixedSearchResults(new List<Id>{ contactId });

        Test.startTest();
        Integer before = Limits.getSoslQueries();
        ConsentSelector.SearchResults results = SELECTOR.searchEverywhere('Contact', 20);
        Integer used = Limits.getSoslQueries() - before;
        Test.stopTest();

        Assert.areEqual(1, used, 'Searching three objects must cost one SOSL query, not one query per object.');
        Assert.areEqual(1, results.contacts.size(), 'The fixed search result should come back.');
        Assert.isTrue(results.totalSize() >= 1, 'The grouped total should reflect what was found.');
    }

    @IsTest
    static void searchEverywhere_shortTermsSkipTheQuery() {
        Test.startTest();
        Integer before = Limits.getSoslQueries();
        ConsentSelector.SearchResults oneChar = SELECTOR.searchEverywhere('a', 20);
        ConsentSelector.SearchResults blank = SELECTOR.searchEverywhere('   ', 20);
        Integer used = Limits.getSoslQueries() - before;
        Test.stopTest();

        Assert.areEqual(0, used, 'SOSL needs two characters; a short term must not reach the search index.');
        Assert.areEqual(0, oneChar.totalSize(), 'A one-character term yields nothing.');
        Assert.areEqual(0, blank.totalSize(), 'A blank term yields nothing.');
    }

    @IsTest
    static void escapeSosl_escapesTheReservedSetNotJustQuotes() {
        // These are SOSL reserved characters, a different list from SOQL's.
        String escaped = ConsentSelector.escapeSosl('find? this* {and} this');

        Assert.isTrue(escaped.contains('\\?'), 'A question mark is a SOSL wildcard and must be escaped.');
        Assert.isTrue(escaped.contains('\\*'), 'An asterisk is a SOSL wildcard and must be escaped.');
        Assert.isTrue(escaped.contains('\\{'), 'Braces are reserved and must be escaped.');
    }
}
