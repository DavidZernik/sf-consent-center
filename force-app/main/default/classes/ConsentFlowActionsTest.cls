/**
 * Tests for the Flow invocable.
 *
 * The size-and-order contract is the thing most worth pinning: Flow bulkifies interviews, and an
 * invocable that returns a differently-sized list silently misassigns results to records.
 */
@IsTest
private class ConsentFlowActionsTest {

    @IsTest
    static void applyConsent_returnsOneResultPerRequestInOrder() {
        List<Contact> contacts = TestDataFactory.createContacts(3);
        List<ConsentFlowActions.ApplyConsentRequest> requests =
            new List<ConsentFlowActions.ApplyConsentRequest>{
                request(contacts[0].Id, 'Email', false, 'Flow'),
                request(null, 'Email', false, 'Flow'),            // invalid on purpose
                request(contacts[2].Id, 'SMS', true, 'Flow')
            };

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        List<ConsentFlowActions.ApplyConsentResult> results = ConsentFlowActions.applyConsent(requests);
        Test.stopTest();

        Assert.areEqual(3, results.size(), 'One result per request, always.');
        Assert.isTrue(results[0].success, 'Request 0 was valid.');
        Assert.isFalse(results[1].success, 'Request 1 had no contact and must fail in place.');
        Assert.isTrue(results[2].success, 'Request 2 was valid and must not be affected by request 1 failing.');
        Assert.areEqual(
            'Contact and channel are both required.',
            results[1].message,
            'The failing record should carry its own reason.'
        );
    }

    @IsTest
    static void applyConsent_reportsNoOpsAsUnchanged() {
        Contact contact = TestDataFactory.createContacts(1)[0];
        TestDataFactory.createPreferencesForAllChannels(new List<Contact>{ contact }, true);

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        List<ConsentFlowActions.ApplyConsentResult> results = ConsentFlowActions.applyConsent(
            new List<ConsentFlowActions.ApplyConsentRequest>{ request(contact.Id, 'Email', true, 'Flow') }
        );
        Test.stopTest();

        Assert.isTrue(results[0].success, 'A no-op is a success, not a failure.');
        Assert.isFalse(results[0].changed, 'The caller needs to know nothing actually moved.');
        Assert.areEqual(
            0,
            [SELECT COUNT() FROM Consent_History__c],
            'A no-op must not write an audit row.'
        );
    }

    @IsTest
    static void applyConsent_writesTheAuditTrail() {
        Contact contact = TestDataFactory.createContacts(1)[0];

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        ConsentFlowActions.applyConsent(
            new List<ConsentFlowActions.ApplyConsentRequest>{ request(contact.Id, 'Email', false, 'Support Case') }
        );
        Test.stopTest();

        Consent_History__c audit = [
            SELECT Previous_Value__c, New_Value__c, Change_Source__c FROM Consent_History__c
        ];
        Assert.areEqual('None', audit.Previous_Value__c, 'First-ever record has no previous value.');
        Assert.areEqual('Opted Out', audit.New_Value__c, 'The new value should be recorded.');
        Assert.areEqual('Support Case', audit.Change_Source__c, 'The Flow-supplied source must survive.');
    }

    @IsTest
    static void applyConsent_isBulkSafeForAFullInterviewBatch() {
        List<Contact> contacts = TestDataFactory.createContacts(200);
        List<ConsentFlowActions.ApplyConsentRequest> requests =
            new List<ConsentFlowActions.ApplyConsentRequest>();
        for (Contact contact : contacts) {
            requests.add(request(contact.Id, 'Email', false, 'Flow'));
        }

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        List<ConsentFlowActions.ApplyConsentResult> results = ConsentFlowActions.applyConsent(requests);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(200, results.size(), 'Every request needs a result.');
        Assert.isTrue(
            queriesUsed <= 2,
            'A 200-record interview batch must not scale queries with batch size. Used: ' + queriesUsed
        );
        Assert.areEqual(200, [SELECT COUNT() FROM Consent_Preference__c], 'All 200 should have been written.');
    }

    @IsTest
    static void applyConsent_emptyAndNullInputAreSafe() {
        Test.startTest();
        Assert.areEqual(0, ConsentFlowActions.applyConsent(null).size(), 'Null input must not throw.');
        Assert.areEqual(
            0,
            ConsentFlowActions.applyConsent(new List<ConsentFlowActions.ApplyConsentRequest>()).size(),
            'Empty input must not throw.'
        );
        Test.stopTest();
    }

    private static ConsentFlowActions.ApplyConsentRequest request(Id contactId, String channel, Boolean optIn, String source) {
        ConsentFlowActions.ApplyConsentRequest r = new ConsentFlowActions.ApplyConsentRequest();
        r.contactId = contactId;
        r.channel = channel;
        r.optIn = optIn;
        r.source = source;
        return r;
    }
}
