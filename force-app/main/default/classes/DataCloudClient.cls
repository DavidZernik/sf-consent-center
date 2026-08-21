/**
 * HTTP client for the Data Cloud Query API (v2).
 *
 * The v2 response is column-oriented — a metadata map describing each column and its position,
 * plus a list of positional value arrays. This class zips those back into row maps so callers
 * work with named fields instead of array indices, which is where off-by-one bugs live.
 *
 * ConnectApi.CdpQuery is the other way to reach Data Cloud from Apex. REST over a Named
 * Credential is used here because ConnectApi query methods cannot be mocked in a test context,
 * and an integration that cannot be tested is not one worth shipping.
 */
public with sharing class DataCloudClient {
    private static final Integer CALLOUT_TIMEOUT_MS = 60000;

    /** Rows plus the paging cursor, if the result set was truncated. */
    public class QueryResult {
        public List<Map<String, Object>> rows = new List<Map<String, Object>>();
        public Integer rowCount = 0;
        public Boolean done = true;
        public String nextBatchId;
        public Long durationMs = 0;
    }

    /**
     * Runs an ANSI SQL statement against Data Cloud.
     *
     * @param sql A statement built through DataCloudQuery. Never pass raw user input.
     */
    public QueryResult query(String sql) {
        if (String.isBlank(sql)) {
            throw new ConsentCenterException('A SQL statement is required.');
        }

        Long startedAt = System.currentTimeMillis();
        DataCloudAuth.Token token = DataCloudAuth.getToken();

        HttpRequest req = new HttpRequest();
        req.setEndpoint(token.baseUrl() + '/api/v2/query');
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + token.accessToken);
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(CALLOUT_TIMEOUT_MS);
        req.setBody(JSON.serialize(new Map<String, Object>{ 'sql' => sql }));

        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (System.CalloutException e) {
            throw new ConsentCenterException('Data Cloud query failed: ' + e.getMessage());
        }

        if (res.getStatusCode() == 401) {
            DataCloudAuth.invalidate();
            throw new ConsentCenterException('Data Cloud rejected the access token.');
        }
        // 200 = complete result set, 206 = partial content with further batches to fetch.
        if (res.getStatusCode() != 200 && res.getStatusCode() != 206) {
            throw new ConsentCenterException(
                'Data Cloud query failed (HTTP ' + res.getStatusCode() + '): ' + res.getBody()
            );
        }

        QueryResult result = parse(res.getBody());
        result.durationMs = System.currentTimeMillis() - startedAt;
        return result;
    }

    /**
     * Turns the column-oriented v2 payload into row maps.
     *
     * Columns are ordered by their placeInOrder rather than by map iteration order, because
     * Apex map ordering is not guaranteed and the API does not promise key order either.
     */
    @TestVisible
    private static QueryResult parse(String body) {
        QueryResult result = new QueryResult();
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(body);

        Map<String, Object> metadata = (Map<String, Object>) parsed.get('metadata');
        if (metadata == null || metadata.isEmpty()) {
            return result;
        }

        Map<Integer, String> columnByPosition = new Map<Integer, String>();
        for (String columnName : metadata.keySet()) {
            Map<String, Object> columnMeta = (Map<String, Object>) metadata.get(columnName);
            columnByPosition.put(Integer.valueOf(columnMeta.get('placeInOrder')), columnName);
        }

        List<Object> data = (List<Object>) parsed.get('data');
        if (data != null) {
            for (Object rowObject : data) {
                List<Object> values = (List<Object>) rowObject;
                Map<String, Object> row = new Map<String, Object>();
                for (Integer i = 0; i < values.size(); i++) {
                    String columnName = columnByPosition.get(i);
                    if (columnName != null) {
                        row.put(columnName, values[i]);
                    }
                }
                result.rows.add(row);
            }
        }

        result.rowCount = parsed.get('rowCount') == null ? result.rows.size() : Integer.valueOf(parsed.get('rowCount'));
        result.done = parsed.get('done') == null ? true : (Boolean) parsed.get('done');
        result.nextBatchId = (String) parsed.get('nextBatchId');
        return result;
    }
}
