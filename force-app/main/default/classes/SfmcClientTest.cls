/**
 * Tests for the Marketing Cloud HTTP client.
 *
 * The important behaviour here is classification: which failures are worth retrying and which
 * are permanent. Getting that wrong either hammers the tenant or silently drops consent.
 */
@IsTest
private class SfmcClientTest {

    @IsTest
    static void upsertRows_successReturnsAcceptedCount() {
        TestDataFactory.primeSfmcToken();
        SfmcCalloutMock mock = SfmcCalloutMock.success();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        SfmcClient.SyncResponse response = new SfmcClient().upsertRows('Consent_Preferences', sampleRows(3));
        Test.stopTest();

        Assert.isTrue(response.success, 'A 202 should be treated as success.');
        Assert.areEqual(202, response.statusCode, 'Status code should be passed through.');
        Assert.areEqual(3, response.rowsAccepted, 'All submitted rows should be counted as accepted.');
        Assert.isFalse(response.retryable, 'A success is never retryable.');
        Assert.areEqual(1, mock.rowsetCallCount, 'Three rows belong in a single request.');
    }

    @IsTest
    static void upsertRows_serverErrorIsRetryable() {
        TestDataFactory.primeSfmcToken();
        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.serverError());

        Test.startTest();
        SfmcClient.SyncResponse response = new SfmcClient().upsertRows('Consent_Preferences', sampleRows(1));
        Test.stopTest();

        Assert.isFalse(response.success, 'A 500 is a failure.');
        Assert.isTrue(response.retryable, 'A 5xx is transient and should be retried.');
        Assert.areEqual(500, response.statusCode, 'Status code should be recorded for the console.');
        Assert.isNotNull(response.errorMessage, 'The response body should be captured for diagnosis.');
    }

    @IsTest
    static void upsertRows_badRequestIsNotRetryable() {
        TestDataFactory.primeSfmcToken();
        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.badRequest());

        Test.startTest();
        SfmcClient.SyncResponse response = new SfmcClient().upsertRows('Consent_Preferences', sampleRows(1));
        Test.stopTest();

        Assert.isFalse(response.success, 'A 400 is a failure.');
        Assert.isFalse(
            response.retryable,
            'Replaying an identical malformed payload would fail identically, so it must not be retried.'
        );
    }

    @IsTest
    static void upsertRows_throttlingIsRetryable() {
        TestDataFactory.primeSfmcToken();
        Test.setMock(HttpCalloutMock.class, new SfmcCalloutMock(429, '{"message":"Too Many Requests"}'));

        Test.startTest();
        SfmcClient.SyncResponse response = new SfmcClient().upsertRows('Consent_Preferences', sampleRows(1));
        Test.stopTest();

        Assert.isTrue(response.retryable, 'A 429 must back off and retry rather than drop the change.');
    }

    @IsTest
    static void upsertRows_unauthorizedInvalidatesCachedToken() {
        TestDataFactory.primeSfmcToken();
        Assert.isNotNull(SfmcAuth.transactionToken, 'Precondition: a token is cached.');
        Test.setMock(HttpCalloutMock.class, new SfmcCalloutMock(401, '{"message":"Not Authorized"}'));

        Test.startTest();
        SfmcClient.SyncResponse response = new SfmcClient().upsertRows('Consent_Preferences', sampleRows(1));
        Test.stopTest();

        Assert.isTrue(response.retryable, 'A rejected token should be retried after re-authenticating.');
        Assert.isNull(SfmcAuth.transactionToken, 'The stale token must be dropped so the retry re-authenticates.');
    }

    @IsTest
    static void upsertRows_emptyListShortCircuitsWithoutCallout() {
        TestDataFactory.primeSfmcToken();
        SfmcCalloutMock mock = SfmcCalloutMock.success();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        SfmcClient.SyncResponse response = new SfmcClient().upsertRows('Consent_Preferences', new List<Map<String, Object>>());
        Test.stopTest();

        Assert.isTrue(response.success, 'Nothing to send is a success, not an error.');
        Assert.areEqual(0, mock.rowsetCallCount, 'No rows means no callout should be burned.');
    }

    @IsTest
    static void upsertRows_oversizedBatchIsRejectedBeforeCallout() {
        TestDataFactory.primeSfmcToken();
        SfmcCalloutMock mock = SfmcCalloutMock.success();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        try {
            new SfmcClient().upsertRows('Consent_Preferences', sampleRows(SfmcClient.MAX_ROWS_PER_REQUEST + 1));
            Assert.fail('An oversized batch should be rejected by the client, not by the tenant.');
        } catch (ConsentCenterException e) {
            Assert.isTrue(e.getMessage().contains('51'), 'The error should state the attempted size. Got: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.areEqual(0, mock.rowsetCallCount, 'The guard must fire before any HTTP traffic.');
    }

    @IsTest
    static void upsertRows_blankDataExtensionKeyIsRejected() {
        TestDataFactory.primeSfmcToken();
        try {
            new SfmcClient().upsertRows('   ', sampleRows(1));
            Assert.fail('A blank Data Extension key should be rejected.');
        } catch (ConsentCenterException e) {
            Assert.isTrue(e.getMessage().contains('external key'), 'Message should name the missing input.');
        }
    }

    @IsTest
    static void toRow_shapesTheDataExtensionPayload() {
        Contact c = TestDataFactory.createContacts(1)[0];
        Consent_Preference__c pref = TestDataFactory.buildPreference(c.Id, 'Email', true);
        insert pref;
        pref = [
            SELECT Id, Contact__c, Contact__r.Email, Channel__c, Opt_In__c, Consent_Source__c, Last_Changed__c
            FROM Consent_Preference__c WHERE Id = :pref.Id
        ];

        Map<String, Object> row = SfmcClient.toRow(pref);
        Map<String, Object> keys = (Map<String, Object>) row.get('keys');
        Map<String, Object> values = (Map<String, Object>) row.get('values');

        Assert.areEqual(c.Id, keys.get('SubscriberKey'), 'SubscriberKey must be the contact id.');
        Assert.areEqual('Email', keys.get('Channel'), 'Channel is part of the composite key.');
        Assert.areEqual(true, values.get('OptIn'), 'Opt-in state must survive the mapping.');
        Assert.isTrue(
            ((String) values.get('LastChanged')).endsWith('Z'),
            'Timestamps must be sent as UTC so the tenant timezone cannot shift them.'
        );
    }

    @IsTest
    static void getToken_authFailureSurfacesAsDomainException() {
        SfmcAuth.transactionToken = null;
        Test.setMock(HttpCalloutMock.class, new SfmcCalloutMock(202, '{}', 401));

        Test.startTest();
        try {
            SfmcAuth.getToken();
            Assert.fail('A rejected client credential should raise an error.');
        } catch (ConsentCenterException e) {
            Assert.isTrue(
                e.getMessage().contains('authentication failed'),
                'The message should make the auth hop obvious. Got: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void getToken_cachesWithinTransaction() {
        SfmcAuth.transactionToken = null;
        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());

        Test.startTest();
        SfmcAuth.Token first = SfmcAuth.getToken();
        SfmcAuth.Token second = SfmcAuth.getToken();
        Integer calloutsUsed = Limits.getCallouts();
        Test.stopTest();

        Assert.areEqual('mock-token', first.accessToken, 'Token should be parsed from the response.');
        Assert.areEqual(first.accessToken, second.accessToken, 'The second call should reuse the cached token.');
        Assert.areEqual(1, calloutsUsed, 'Only one authentication callout should be spent per transaction.');
    }

    private static List<Map<String, Object>> sampleRows(Integer count) {
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        for (Integer i = 0; i < count; i++) {
            rows.add(new Map<String, Object>{
                'keys' => new Map<String, Object>{ 'SubscriberKey' => 'sub-' + i, 'Channel' => 'Email' },
                'values' => new Map<String, Object>{ 'OptIn' => true }
            });
        }
        return rows;
    }
}
