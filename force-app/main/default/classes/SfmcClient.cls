/**
 * Thin HTTP client for the Marketing Cloud REST API.
 *
 * Only responsibility is turning consent records into Data Extension rows and reporting
 * what the tenant said back. Retry policy, logging and record updates deliberately live in
 * SfmcSyncQueueable so this class stays trivially mockable.
 */
// The Authorization header carries a token minted through the SFMC_Auth Named
// Credential. It is set by hand because Marketing Cloud returns a tenant-specific
// rest_instance_url that the callout must target, which a Named Credential cannot express.
@SuppressWarnings('PMD.ApexSuggestUsingNamedCred')
public with sharing class SfmcClient {
    /** SFMC rejects rowset payloads far above this; batching is the caller's job. */
    public static final Integer MAX_ROWS_PER_REQUEST = 50;
    private static final Integer CALLOUT_TIMEOUT_MS = 60000;

    /** Normalised result of one rowset upsert. */
    public class SyncResponse {
        public Boolean success;
        public Integer statusCode;
        public Integer rowsAccepted;
        public String errorMessage;
        /** True when a retry could plausibly succeed (throttling, 5xx, expired token). */
        public Boolean retryable;
        public Long durationMs;
    }

    /**
     * Upserts rows into a Data Extension via the hub dataevents endpoint.
     *
     * @param deExternalKey External key of the target Data Extension.
     * @param rows          Payload rows, each {keys: {...}, values: {...}}.
     * @throws ConsentCenterException when called with more rows than one request allows.
     */
    public SyncResponse upsertRows(String deExternalKey, List<Map<String, Object>> rows) {
        if (String.isBlank(deExternalKey)) {
            throw new ConsentCenterException('A Data Extension external key is required.');
        }
        if (rows == null || rows.isEmpty()) {
            SyncResponse empty = new SyncResponse();
            empty.success = true;
            empty.statusCode = 204;
            empty.rowsAccepted = 0;
            empty.retryable = false;
            empty.durationMs = 0;
            return empty;
        }
        if (rows.size() > MAX_ROWS_PER_REQUEST) {
            throw new ConsentCenterException(
                'Refusing to send ' + rows.size() + ' rows in one request; the limit is ' + MAX_ROWS_PER_REQUEST + '.'
            );
        }

        Long startedAt = System.currentTimeMillis();
        SfmcAuth.Token token = SfmcAuth.getToken();

        HttpRequest req = new HttpRequest();
        req.setEndpoint(token.restInstanceUrl + 'hub/v1/dataevents/key:' + EncodingUtil.urlEncode(deExternalKey, 'UTF-8') + '/rowset');
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + token.accessToken);
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(CALLOUT_TIMEOUT_MS);
        req.setBody(JSON.serialize(rows));

        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (System.CalloutException e) {
            // Socket-level failure: nothing was necessarily delivered, so this is retryable.
            return failure(null, 'Callout failed: ' + e.getMessage(), true, System.currentTimeMillis() - startedAt);
        }

        Long elapsed = System.currentTimeMillis() - startedAt;
        Integer status = res.getStatusCode();

        if (status == 200 || status == 202) {
            SyncResponse ok = new SyncResponse();
            ok.success = true;
            ok.statusCode = status;
            ok.rowsAccepted = rows.size();
            ok.retryable = false;
            ok.durationMs = elapsed;
            return ok;
        }

        if (status == 401) {
            // Token was rejected, drop it so the next attempt authenticates cleanly.
            SfmcAuth.invalidate();
            return failure(status, 'Access token rejected by Marketing Cloud.', true, elapsed);
        }

        // 429 and 5xx are transient; 4xx of any other shape means the payload is wrong and
        // replaying it unchanged would fail identically.
        Boolean retryable = (status == 429 || status >= 500);
        return failure(status, truncate(res.getBody(), 255), retryable, elapsed);
    }

    /** Shapes one consent record into the rowset entry the Data Extension expects. */
    public static Map<String, Object> toRow(Consent_Preference__c pref) {
        return new Map<String, Object>{
            'keys' => new Map<String, Object>{
                'SubscriberKey' => pref.Contact__c,
                'Channel' => pref.Channel__c
            },
            'values' => new Map<String, Object>{
                'EmailAddress' => pref.Contact__r == null ? null : pref.Contact__r.Email,
                'OptIn' => pref.Opt_In__c == true,
                'ConsentSource' => pref.Consent_Source__c,
                'LastChanged' => pref.Last_Changed__c == null
                    ? null
                    : pref.Last_Changed__c.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'')
            }
        };
    }

    private SyncResponse failure(Integer status, String message, Boolean retryable, Long elapsed) {
        SyncResponse r = new SyncResponse();
        r.success = false;
        r.statusCode = status;
        r.rowsAccepted = 0;
        r.errorMessage = message;
        r.retryable = retryable;
        r.durationMs = elapsed;
        return r;
    }

    private static String truncate(String value, Integer max) {
        if (String.isBlank(value)) {
            return null;
        }
        return value.length() <= max ? value : value.substring(0, max);
    }
}
