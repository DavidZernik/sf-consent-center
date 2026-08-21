/**
 * Data Cloud token exchange.
 *
 * Data Cloud does not accept a core Salesforce session directly. The core access token is
 * swapped for a Data Cloud token at /services/a360/token using the CDP external grant, and the
 * response carries its own instance host. Data Cloud lives on a different domain from the
 * core org, so both halves must be kept together or the query call 404s.
 *
 * Tokens are short lived (typically ~30 minutes) and the exchange is not free, so the same
 * three-tier cache used for Marketing Cloud applies here.
 */
public with sharing class DataCloudAuth {
    private static final String CDP_GRANT_TYPE = 'urn:salesforce:grant-type:external:cdp';
    private static final Integer EXPIRY_SAFETY_WINDOW_SECONDS = 120;
    private static final String CACHE_PARTITION = 'local.ConsentCenter';
    private static final String CACHE_KEY = 'dataCloudToken';

    @TestVisible
    private static Token transactionToken;

    /** Data Cloud access token plus the tenant host it is valid against. */
    public class Token {
        public String accessToken;
        /** Host only, no scheme. This is exactly what the API returns. */
        public String instanceUrl;
        public Datetime expiresAt;

        public Boolean isUsable() {
            return String.isNotBlank(accessToken)
                && String.isNotBlank(instanceUrl)
                && expiresAt != null
                && expiresAt > Datetime.now();
        }

        /** Absolute base URL for Data Cloud API calls. */
        public String baseUrl() {
            return instanceUrl.startsWith('https://') ? instanceUrl : 'https://' + instanceUrl;
        }
    }

    public static Token getToken() {
        if (transactionToken != null && transactionToken.isUsable()) {
            return transactionToken;
        }
        Token cached = readFromPlatformCache();
        if (cached != null && cached.isUsable()) {
            transactionToken = cached;
            return cached;
        }
        Token fresh = exchangeToken();
        transactionToken = fresh;
        writeToPlatformCache(fresh);
        return fresh;
    }

    public static void invalidate() {
        transactionToken = null;
        try {
            Cache.Org.getPartition(CACHE_PARTITION).remove(CACHE_KEY);
        } catch (Exception ignored) {
            // Platform Cache is optional; clearing the static cache is enough for correctness.
        }
    }

    private static Token exchangeToken() {
        HttpRequest req = new HttpRequest();
        // Named Credential points at the org's own My Domain. The External Credential supplies
        // the connected-app JWT used as the subject token.
        req.setEndpoint('callout:Data_Cloud/services/a360/token');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
        req.setTimeout(20000);
        req.setBody('grant_type=' + EncodingUtil.urlEncode(CDP_GRANT_TYPE, 'UTF-8'));

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            throw new ConsentCenterException(
                'Data Cloud token exchange failed (HTTP ' + res.getStatusCode() + '): ' + res.getBody()
            );
        }

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        Token t = new Token();
        t.accessToken = (String) body.get('access_token');
        t.instanceUrl = (String) body.get('instance_url');
        Integer expiresIn = body.get('expires_in') == null ? 1800 : Integer.valueOf(body.get('expires_in'));
        t.expiresAt = Datetime.now().addSeconds(Math.max(expiresIn - EXPIRY_SAFETY_WINDOW_SECONDS, 60));

        if (String.isBlank(t.accessToken) || String.isBlank(t.instanceUrl)) {
            throw new ConsentCenterException(
                'Data Cloud returned an incomplete token response; both access_token and instance_url are required.'
            );
        }
        return t;
    }

    private static Token readFromPlatformCache() {
        try {
            Object raw = Cache.Org.getPartition(CACHE_PARTITION).get(CACHE_KEY);
            return raw == null ? null : (Token) JSON.deserialize((String) raw, Token.class);
        } catch (Exception ignored) {
            return null;
        }
    }

    private static void writeToPlatformCache(Token t) {
        try {
            Integer ttl = Math.max((Integer) ((t.expiresAt.getTime() - Datetime.now().getTime()) / 1000), 60);
            Cache.Org.getPartition(CACHE_PARTITION).put(CACHE_KEY, JSON.serialize(t), ttl);
        } catch (Exception ignored) {
            // Best effort.
        }
    }
}
