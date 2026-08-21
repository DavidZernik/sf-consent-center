/**
 * Tests for the Data Cloud HTTP client and its token exchange.
 *
 * The response parser is the part worth testing directly. Data Cloud v2 returns column-oriented
 * data (a metadata map giving each column a position, plus positional value arrays) and
 * reassembling that into row maps is exactly where an off-by-one silently mislabels every field
 * in the result set.
 */
@IsTest
private class DataCloudClientTest {

    /* --------------------------------------------------------------- Response parsing */

    @IsTest
    static void query_mapsColumnsByDeclaredPositionNotMapOrder() {
        DataCloudAuth.transactionToken = primedToken();
        // placeInOrder deliberately disagrees with the key order in the JSON object. Apex map
        // iteration order is not guaranteed, so a parser that trusts key order gets this wrong.
        String body =
            '{"data":[["second-value","first-value"]],' +
            '"metadata":{"ColumnB":{"placeInOrder":0,"type":"VARCHAR"},' +
            '"ColumnA":{"placeInOrder":1,"type":"VARCHAR"}},' +
            '"rowCount":1,"done":true}';
        Test.setMock(HttpCalloutMock.class, new DataCloudCalloutMock(new List<String>{ body }));

        Test.startTest();
        DataCloudClient.QueryResult result = new DataCloudClient().query('SELECT ColumnA, ColumnB FROM x__dlm');
        Test.stopTest();

        Assert.areEqual(1, result.rows.size(), 'One row in, one row out.');
        Assert.areEqual('second-value', result.rows[0].get('ColumnB'), 'Position 0 belongs to ColumnB.');
        Assert.areEqual('first-value', result.rows[0].get('ColumnA'), 'Position 1 belongs to ColumnA.');
    }

    @IsTest
    static void query_handlesNullValuesInsideRows() {
        DataCloudAuth.transactionToken = primedToken();
        String body =
            '{"data":[["present",null]],' +
            '"metadata":{"A":{"placeInOrder":0,"type":"VARCHAR"},"B":{"placeInOrder":1,"type":"VARCHAR"}},' +
            '"rowCount":1,"done":true}';
        Test.setMock(HttpCalloutMock.class, new DataCloudCalloutMock(new List<String>{ body }));

        Test.startTest();
        DataCloudClient.QueryResult result = new DataCloudClient().query('SELECT A, B FROM x__dlm');
        Test.stopTest();

        Assert.areEqual('present', result.rows[0].get('A'), 'A non-null value should survive.');
        Assert.isNull(result.rows[0].get('B'), 'A null must stay null, not become an empty string.');
    }

    @IsTest
    static void query_emptyResultSetIsNotAnError() {
        DataCloudAuth.transactionToken = primedToken();
        Test.setMock(HttpCalloutMock.class, new DataCloudCalloutMock(new List<String>{
            DataCloudCalloutMock.emptyResult()
        }));

        Test.startTest();
        DataCloudClient.QueryResult result = new DataCloudClient().query('SELECT a FROM x__dlm');
        Test.stopTest();

        Assert.areEqual(0, result.rows.size(), 'No rows.');
        Assert.areEqual(0, result.rowCount, 'Row count should be zero, not null.');
        Assert.isTrue(result.done, 'An empty result set is complete.');
    }

    @IsTest
    static void query_carriesThePagingCursorWhenTruncated() {
        DataCloudAuth.transactionToken = primedToken();
        String body =
            '{"data":[["x"]],"metadata":{"A":{"placeInOrder":0,"type":"VARCHAR"}},' +
            '"rowCount":1,"done":false,"nextBatchId":"batch-77"}';
        Test.setMock(HttpCalloutMock.class, new DataCloudCalloutMock(new List<String>{ body }, 206, 200));

        Test.startTest();
        DataCloudClient.QueryResult result = new DataCloudClient().query('SELECT A FROM x__dlm');
        Test.stopTest();

        Assert.isFalse(result.done, 'A 206 means more batches remain.');
        Assert.areEqual('batch-77', result.nextBatchId, 'The cursor must be surfaced or paging is impossible.');
    }

    @IsTest
    static void query_recordsHowLongTheCallTook() {
        DataCloudAuth.transactionToken = primedToken();
        Test.setMock(HttpCalloutMock.class, new DataCloudCalloutMock(new List<String>{
            DataCloudCalloutMock.emptyResult()
        }));

        Test.startTest();
        DataCloudClient.QueryResult result = new DataCloudClient().query('SELECT a FROM x__dlm');
        Test.stopTest();

        Assert.isTrue(result.durationMs >= 0, 'Timing is shown in the UI and must be populated.');
    }

    /* ------------------------------------------------------------------- Failure paths */

    @IsTest
    static void query_blankSqlIsRejectedBeforeAnyCallout() {
        DataCloudAuth.transactionToken = primedToken();
        try {
            new DataCloudClient().query('   ');
            Assert.fail('Blank SQL should be rejected.');
        } catch (ConsentCenterException e) {
            Assert.isTrue(e.getMessage().contains('SQL statement is required'), 'Got: ' + e.getMessage());
        }
    }

    @IsTest
    static void query_unauthorizedClearsTheCachedToken() {
        DataCloudAuth.transactionToken = primedToken();
        Test.setMock(HttpCalloutMock.class, new DataCloudCalloutMock(new List<String>{ '{}' }, 401, 200));

        Test.startTest();
        try {
            new DataCloudClient().query('SELECT a FROM x__dlm');
            Assert.fail('A 401 should raise.');
        } catch (ConsentCenterException e) {
            Assert.isTrue(e.getMessage().contains('rejected the access token'), 'Got: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isNull(DataCloudAuth.transactionToken, 'A rejected token must not be reused on the next attempt.');
    }

    @IsTest
    static void query_serverErrorIncludesTheStatusCode() {
        DataCloudAuth.transactionToken = primedToken();
        Test.setMock(HttpCalloutMock.class, new DataCloudCalloutMock(
            new List<String>{ '{"message":"boom"}' }, 500, 200
        ));

        Test.startTest();
        try {
            new DataCloudClient().query('SELECT a FROM x__dlm');
            Assert.fail('A 500 should raise.');
        } catch (ConsentCenterException e) {
            Assert.isTrue(e.getMessage().contains('500'), 'The status belongs in the message. Got: ' + e.getMessage());
        }
        Test.stopTest();
    }

    /* ------------------------------------------------------------------ Token exchange */

    @IsTest
    static void getToken_exchangesAndKeepsTheInstanceHost() {
        DataCloudAuth.transactionToken = null;
        Test.setMock(HttpCalloutMock.class, new DataCloudCalloutMock(new List<String>{
            DataCloudCalloutMock.emptyResult()
        }));

        Test.startTest();
        DataCloudAuth.Token token = DataCloudAuth.getToken();
        Test.stopTest();

        Assert.areEqual('dc-token', token.accessToken, 'The access token should be parsed.');
        Assert.areEqual('tenant.c360a.salesforce.com', token.instanceUrl, 'Data Cloud lives on its own host.');
        Assert.areEqual(
            'https://tenant.c360a.salesforce.com',
            token.baseUrl(),
            'The API returns a bare host; the client has to add the scheme itself.'
        );
        Assert.isTrue(token.isUsable(), 'A freshly minted token should be usable.');
    }

    @IsTest
    static void getToken_cachesForTheRestOfTheTransaction() {
        DataCloudAuth.transactionToken = null;
        Test.setMock(HttpCalloutMock.class, new DataCloudCalloutMock(new List<String>{
            DataCloudCalloutMock.emptyResult()
        }));

        Test.startTest();
        DataCloudAuth.getToken();
        DataCloudAuth.getToken();
        Integer callouts = Limits.getCallouts();
        Test.stopTest();

        Assert.areEqual(1, callouts, 'The token exchange should be spent once per transaction, not per query.');
    }

    @IsTest
    static void getToken_failedExchangeSurfacesAsADomainException() {
        DataCloudAuth.transactionToken = null;
        Test.setMock(HttpCalloutMock.class, new DataCloudCalloutMock(new List<String>(), 200, 400));

        Test.startTest();
        try {
            DataCloudAuth.getToken();
            Assert.fail('A rejected grant should raise.');
        } catch (ConsentCenterException e) {
            Assert.isTrue(
                e.getMessage().contains('token exchange failed'),
                'The message should name the failing hop. Got: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void token_expiryIsRespected() {
        DataCloudAuth.Token expired = new DataCloudAuth.Token();
        expired.accessToken = 'stale';
        expired.instanceUrl = 'tenant.c360a.salesforce.com';
        expired.expiresAt = Datetime.now().addMinutes(-1);

        Assert.isFalse(expired.isUsable(), 'An expired token must not be treated as usable.');

        DataCloudAuth.Token incomplete = new DataCloudAuth.Token();
        incomplete.accessToken = 'present';
        incomplete.expiresAt = Datetime.now().addMinutes(10);
        Assert.isFalse(
            incomplete.isUsable(),
            'A token with no instance host is unusable. The query would go to the wrong domain.'
        );
    }

    @IsTest
    static void invalidate_clearsTheTransactionCache() {
        DataCloudAuth.transactionToken = primedToken();
        Test.startTest();
        DataCloudAuth.invalidate();
        Test.stopTest();

        Assert.isNull(DataCloudAuth.transactionToken, 'invalidate must clear the cached token.');
    }

    private static DataCloudAuth.Token primedToken() {
        DataCloudAuth.Token token = new DataCloudAuth.Token();
        token.accessToken = 'test-token';
        token.instanceUrl = 'tenant.c360a.salesforce.com';
        token.expiresAt = Datetime.now().addMinutes(20);
        return token;
    }
}
