/**
 * Routing HTTP mock for the Marketing Cloud endpoints.
 *
 * One mock handles both the token call and the rowset call because a single Apex transaction
 * only accepts one Test.setMock per interface. Routing on the endpoint is the standard way
 * to cover a multi-hop integration.
 */
@IsTest
public class SfmcCalloutMock implements HttpCalloutMock {
    private final Integer rowsetStatus;
    private final String rowsetBody;
    private final Integer authStatus;

    /** Number of rowset calls this mock saw, so tests can assert batching behaviour. */
    public Integer rowsetCallCount = 0;
    /** Body of the most recent rowset call, for payload assertions. */
    public String lastRowsetBody;

    public SfmcCalloutMock(Integer rowsetStatus, String rowsetBody) {
        this(rowsetStatus, rowsetBody, 200);
    }

    public SfmcCalloutMock(Integer rowsetStatus, String rowsetBody, Integer authStatus) {
        this.rowsetStatus = rowsetStatus;
        this.rowsetBody = rowsetBody;
        this.authStatus = authStatus;
    }

    /** Convenience: the happy path both hops succeed. */
    public static SfmcCalloutMock success() {
        return new SfmcCalloutMock(202, '{"requestId":"abc-123"}');
    }

    /** Convenience: a transient server error, which SfmcClient must classify as retryable. */
    public static SfmcCalloutMock serverError() {
        return new SfmcCalloutMock(500, '{"message":"Internal Server Error"}');
    }

    /** Convenience: a permanent payload error, which must NOT be retried. */
    public static SfmcCalloutMock badRequest() {
        return new SfmcCalloutMock(400, '{"message":"Invalid Data Extension key"}');
    }

    public HTTPResponse respond(HTTPRequest request) {
        HttpResponse response = new HttpResponse();
        response.setHeader('Content-Type', 'application/json');

        if (request.getEndpoint().contains('/v2/token')) {
            response.setStatusCode(authStatus);
            response.setBody(authStatus == 200
                ? '{"access_token":"mock-token","rest_instance_url":"https://tenant.rest.marketingcloudapis.com/","expires_in":1200}'
                : '{"error":"invalid_client"}');
            return response;
        }

        rowsetCallCount++;
        lastRowsetBody = request.getBody();
        response.setStatusCode(rowsetStatus);
        response.setBody(rowsetBody);
        return response;
    }
}
