/**
 * Tests for the Marketing Cloud SOAP client.
 *
 * The trap this class exists to avoid: SOAP reports application errors inside an HTTP 200. A
 * client that only checks the status code reports every failed unsubscribe as a success, and
 * nobody notices until someone who opted out receives a campaign.
 */
@IsTest
private class SfmcSoapClientTest {

    private class SoapMock implements HttpCalloutMock {
        private final Integer status;
        private final String body;
        public String lastEnvelope;

        SoapMock(Integer status, String body) {
            this.status = status;
            this.body = body;
        }

        public HTTPResponse respond(HTTPRequest request) {
            HttpResponse response = new HttpResponse();
            if (request.getEndpoint().contains('/v2/token')) {
                response.setStatusCode(200);
                response.setBody('{"access_token":"mock-token","rest_instance_url":"https://tenant.rest.marketingcloudapis.com/","expires_in":1200}');
                return response;
            }
            lastEnvelope = request.getBody();
            response.setStatusCode(status);
            response.setHeader('Content-Type', 'text/xml');
            response.setBody(body);
            return response;
        }
    }

    private static String envelope(String overallStatus, String statusCode, String message) {
        return '<?xml version="1.0" encoding="UTF-8"?>'
            + '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">'
            + '<soap:Body><UpdateResponse xmlns="http://exacttarget.com/wsdl/partnerAPI">'
            + '<Results><StatusCode>' + statusCode + '</StatusCode>'
            + '<StatusMessage>' + message + '</StatusMessage></Results>'
            + '<OverallStatus>' + overallStatus + '</OverallStatus>'
            + '</UpdateResponse></soap:Body></soap:Envelope>';
    }

    @IsTest
    static void updateSubscriberStatus_successIsDetectedFromOverallStatus() {
        TestDataFactory.primeSfmcToken();
        Test.setMock(HttpCalloutMock.class, new SoapMock(200, envelope('OK', 'OK', 'Updated Subscriber')));

        Test.startTest();
        SfmcSoapClient.SoapResult result = new SfmcSoapClient().updateSubscriberStatus(
            '003000000000001', 'dana@example.invalid', SfmcSoapClient.SubscriberStatus.UNSUBSCRIBED
        );
        Test.stopTest();

        Assert.isTrue(result.success, 'OverallStatus OK means success.');
        Assert.areEqual('OK', result.statusCode, 'The per-object status code should be parsed.');
        Assert.areEqual('003000000000001', result.subscriberKey, 'The key should be echoed for logging.');
    }

    @IsTest
    static void updateSubscriberStatus_applicationErrorInsideHttp200IsAFailure() {
        TestDataFactory.primeSfmcToken();
        Test.setMock(HttpCalloutMock.class, new SoapMock(
            200, envelope('Error', 'Error', 'Subscriber key is invalid')
        ));

        Test.startTest();
        SfmcSoapClient.SoapResult result = new SfmcSoapClient().updateSubscriberStatus(
            'bad-key', 'dana@example.invalid', SfmcSoapClient.SubscriberStatus.UNSUBSCRIBED
        );
        Test.stopTest();

        Assert.isFalse(
            result.success,
            'A 200 carrying OverallStatus Error is a failed unsubscribe and must be reported as one.'
        );
        Assert.areEqual('Subscriber key is invalid', result.statusMessage, 'The tenant message should surface.');
    }

    @IsTest
    static void updateSubscriberStatus_serverErrorIsRetryable() {
        TestDataFactory.primeSfmcToken();
        Test.setMock(HttpCalloutMock.class, new SoapMock(503, 'Service Unavailable'));

        Test.startTest();
        SfmcSoapClient.SoapResult result = new SfmcSoapClient().updateSubscriberStatus(
            '003000000000001', 'dana@example.invalid', SfmcSoapClient.SubscriberStatus.UNSUBSCRIBED
        );
        Test.stopTest();

        Assert.isFalse(result.success, 'A 503 is a failure.');
        Assert.isTrue(result.retryable, 'A 5xx should be retried.');
    }

    @IsTest
    static void updateSubscriberStatus_unauthorizedInvalidatesTheToken() {
        TestDataFactory.primeSfmcToken();
        Test.setMock(HttpCalloutMock.class, new SoapMock(401, 'Unauthorized'));

        Test.startTest();
        SfmcSoapClient.SoapResult result = new SfmcSoapClient().updateSubscriberStatus(
            '003000000000001', 'dana@example.invalid', SfmcSoapClient.SubscriberStatus.UNSUBSCRIBED
        );
        Test.stopTest();

        Assert.isTrue(result.retryable, 'A rejected token should be retried after re-authenticating.');
        Assert.isNull(SfmcAuth.transactionToken, 'The stale token must be cleared.');
    }

    @IsTest
    static void updateSubscriberStatus_unparseableResponseFailsClosed() {
        TestDataFactory.primeSfmcToken();
        Test.setMock(HttpCalloutMock.class, new SoapMock(200, 'this is not xml at all'));

        Test.startTest();
        SfmcSoapClient.SoapResult result = new SfmcSoapClient().updateSubscriberStatus(
            '003000000000001', 'dana@example.invalid', SfmcSoapClient.SubscriberStatus.UNSUBSCRIBED
        );
        Test.stopTest();

        Assert.isFalse(result.success, 'An unreadable response must never be treated as success.');
        Assert.isTrue(result.retryable, 'It might have been a transient proxy error, so allow a retry.');
    }

    @IsTest
    static void buildUpdateEnvelope_escapesXmlInEveryInterpolatedValue() {
        String envelopeXml = SfmcSoapClient.buildUpdateEnvelope(
            'token', 'key&<>"', 'o\'brien@example.invalid', SfmcSoapClient.SubscriberStatus.UNSUBSCRIBED
        );

        Assert.isTrue(envelopeXml.contains('key&amp;&lt;&gt;&quot;'), 'Reserved XML characters must be escaped.');
        Assert.isTrue(envelopeXml.contains('o&apos;brien@example.invalid'), 'An apostrophe must be escaped.');
        Assert.isFalse(envelopeXml.contains('key&<>"'), 'The raw unescaped value must not appear.');
    }

    @IsTest
    static void buildUpdateEnvelope_usesUpsertSaveAction() {
        String envelopeXml = SfmcSoapClient.buildUpdateEnvelope(
            'token', 'key', 'a@example.invalid', SfmcSoapClient.SubscriberStatus.UNSUBSCRIBED
        );

        Assert.isTrue(
            envelopeXml.contains('UpdateAdd'),
            'Without UpdateAdd, a first-time opt-out for an unknown subscriber fails.'
        );
        Assert.isTrue(envelopeXml.contains('<par:Status>Unsubscribed</par:Status>'), 'Status must map to the SFMC label.');
    }

    @IsTest
    static void updateSubscriberStatus_missingInputsAreRejectedBeforeCallout() {
        TestDataFactory.primeSfmcToken();
        SfmcSoapClient client = new SfmcSoapClient();

        try {
            client.updateSubscriberStatus('', 'a@example.invalid', SfmcSoapClient.SubscriberStatus.ACTIVE);
            Assert.fail('A blank subscriber key should be rejected.');
        } catch (ConsentCenterException e) {
            Assert.isTrue(e.getMessage().contains('subscriber key'), 'Got: ' + e.getMessage());
        }

        try {
            client.updateSubscriberStatus('key', '', SfmcSoapClient.SubscriberStatus.ACTIVE);
            Assert.fail('A blank email should be rejected.');
        } catch (ConsentCenterException e) {
            Assert.isTrue(e.getMessage().contains('email address'), 'Got: ' + e.getMessage());
        }
    }
}
