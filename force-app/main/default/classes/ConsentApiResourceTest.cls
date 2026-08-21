/**
 * Tests for the inbound REST endpoint.
 *
 * HTTP status codes are asserted alongside the payload, because a caller integrating against
 * this endpoint branches on the status long before it parses the body.
 */
@IsTest
private class ConsentApiResourceTest {

    @IsTest
    static void post_appliesConsentAndReturns200() {
        Contact contact = TestDataFactory.createContacts(1)[0];
        setRequest('{"records":[{"email":"' + contact.Email + '","channel":"Email","optIn":false,"source":"Preference Centre","externalReference":"REF-1"}]}');

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        ConsentApiResource.ApiResponse response = ConsentApiResource.upsertConsent();
        Test.stopTest();

        Assert.isTrue(response.success, 'A single valid record should succeed.');
        Assert.areEqual(200, RestContext.response.statusCode, 'A fully successful batch returns 200.');
        Assert.areEqual(1, response.accepted, 'One record accepted.');
        Assert.areEqual('Applied', response.results[0].status, 'The record changed, so status is Applied.');
        Assert.areEqual('REF-1', response.results[0].externalReference, 'The caller reference must be echoed back.');
        Assert.isFalse(
            [SELECT Opt_In__c FROM Consent_Preference__c].Opt_In__c,
            'The opt-out should actually have been written.'
        );
    }

    @IsTest
    static void post_mixedOutcomeReturns207() {
        Contact contact = TestDataFactory.createContacts(1)[0];
        setRequest('{"records":[' +
            '{"email":"' + contact.Email + '","channel":"Email","optIn":true,"externalReference":"OK"},' +
            '{"email":"nobody@example.invalid","channel":"Email","optIn":true,"externalReference":"NOMATCH"}]}');

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        ConsentApiResource.ApiResponse response = ConsentApiResource.upsertConsent();
        Test.stopTest();

        Assert.areEqual(207, RestContext.response.statusCode, 'A partially successful batch is Multi-Status.');
        Assert.areEqual(1, response.accepted, 'One record matched.');
        Assert.areEqual(1, response.rejected, 'One record did not.');
        Assert.areEqual(2, response.results.size(), 'Every submitted record needs an outcome.');
    }

    @IsTest
    static void post_emptyPayloadReturns400() {
        setRequest('{"records":[]}');
        Test.startTest();
        ConsentApiResource.ApiResponse response = ConsentApiResource.upsertConsent();
        Test.stopTest();

        Assert.areEqual(400, RestContext.response.statusCode, 'An empty batch is a bad request.');
        Assert.isFalse(response.success, 'Nothing was accepted.');
    }

    @IsTest
    static void post_malformedJsonReturns400() {
        setRequest('{"records": not json}');
        Test.startTest();
        ConsentApiResource.ApiResponse response = ConsentApiResource.upsertConsent();
        Test.stopTest();

        Assert.areEqual(400, RestContext.response.statusCode, 'Unparseable JSON is a bad request, not a 500.');
        Assert.isTrue(response.message.contains('Malformed JSON'), 'Got: ' + response.message);
    }

    @IsTest
    static void post_oversizedPayloadReturns413() {
        List<String> records = new List<String>();
        for (Integer i = 0; i < 201; i++) {
            records.add('{"email":"a' + i + '@example.invalid","channel":"Email","optIn":true}');
        }
        setRequest('{"records":[' + String.join(records, ',') + ']}');

        Test.startTest();
        ConsentApiResource.ApiResponse response = ConsentApiResource.upsertConsent();
        Test.stopTest();

        Assert.areEqual(413, RestContext.response.statusCode, 'Too many records is Payload Too Large.');
        Assert.isTrue(response.message.contains('200'), 'The limit should be stated. Got: ' + response.message);
    }

    @IsTest
    static void post_missingChannelIsRejectedPerRecord() {
        Contact contact = TestDataFactory.createContacts(1)[0];
        setRequest('{"records":[{"email":"' + contact.Email + '","optIn":true}]}');

        Test.startTest();
        ConsentApiResource.ApiResponse response = ConsentApiResource.upsertConsent();
        Test.stopTest();

        Assert.areEqual('Rejected', response.results[0].status, 'A record with no channel is invalid.');
        Assert.areEqual('A channel is required.', response.results[0].message, 'The reason must be specific.');
    }

    @IsTest
    static void post_resolvesEveryEmailInOneQuery() {
        List<Contact> contacts = TestDataFactory.createContacts(50);
        List<String> records = new List<String>();
        for (Contact contact : contacts) {
            records.add('{"email":"' + contact.Email + '","channel":"Email","optIn":false}');
        }
        setRequest('{"records":[' + String.join(records, ',') + ']}');

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        Integer before = Limits.getQueries();
        ConsentApiResource.ApiResponse response = ConsentApiResource.upsertConsent();
        Integer used = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(50, response.accepted, 'All 50 should have matched.');
        Assert.isTrue(used <= 3, 'Contact resolution must not be one query per record. Used: ' + used);
    }

    @IsTest
    static void get_returnsCurrentConsent() {
        Contact contact = TestDataFactory.createContacts(1)[0];
        TestDataFactory.createPreferencesForAllChannels(new List<Contact>{ contact }, true);
        RestContext.request = new RestRequest();
        RestContext.request.params.put('contactId', contact.Id);
        RestContext.response = new RestResponse();

        Test.startTest();
        ConsentApiResource.ApiResponse response = ConsentApiResource.getConsent();
        Test.stopTest();

        Assert.isTrue(response.success, 'A valid contact should succeed.');
        Assert.areEqual(200, RestContext.response.statusCode, 'A successful read returns 200.');
        Assert.areEqual(4, response.results.size(), 'All four channels should be reported.');
        Assert.areEqual('OptIn', response.results[0].status, 'The fixture is opted in.');
    }

    @IsTest
    static void get_missingParameterReturns400() {
        RestContext.request = new RestRequest();
        RestContext.response = new RestResponse();

        Test.startTest();
        ConsentApiResource.ApiResponse response = ConsentApiResource.getConsent();
        Test.stopTest();

        Assert.areEqual(400, RestContext.response.statusCode, 'A missing parameter is a bad request.');
        Assert.isFalse(response.success, 'Nothing was returned.');
    }

    @IsTest
    static void get_invalidIdReturns400NotAnUnhandledException() {
        RestContext.request = new RestRequest();
        RestContext.request.params.put('contactId', 'not-an-id');
        RestContext.response = new RestResponse();

        Test.startTest();
        ConsentApiResource.ApiResponse response = ConsentApiResource.getConsent();
        Test.stopTest();

        Assert.areEqual(400, RestContext.response.statusCode, 'A malformed id is the caller error, not a server error.');
        Assert.areEqual('That is not a valid record id.', response.message, 'The message should be actionable.');
    }

    private static void setRequest(String body) {
        RestRequest request = new RestRequest();
        request.requestURI = '/services/apexrest/consent/v1/';
        request.httpMethod = 'POST';
        request.requestBody = Blob.valueOf(body);
        RestContext.request = request;
        RestContext.response = new RestResponse();
    }
}
