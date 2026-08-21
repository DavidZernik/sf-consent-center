/**
 * Marketing Cloud OAuth 2.0 client-credentials token handling.
 *
 * SFMC access tokens are short lived (typically 20 minutes) and the tenant returns the
 * REST base URL alongside the token, so both are cached together. Cache order is:
 *   1. static (same transaction — free)
 *   2. Platform Cache org partition (across transactions, best effort)
 *   3. fresh callout
 *
 * Platform Cache is optional in a lot of orgs, so every cache interaction is guarded.
 * A cache miss is a performance problem, never a correctness one.
 */
public with sharing class SfmcAuth {
    /** Refresh this many seconds before real expiry so an in-flight callout cannot race the TTL. */
    private static final Integer EXPIRY_SAFETY_WINDOW_SECONDS = 120;
    private static final String CACHE_PARTITION = 'local.ConsentCenter';
    private static final String CACHE_KEY = 'sfmcToken';

    @TestVisible
    private static Token transactionToken;

    /** Access token plus the tenant-specific REST base URL that must be used with it. */
    public class Token {
        public String accessToken;
        public String restInstanceUrl;
        public Datetime expiresAt;

        public Boolean isUsable() {
            return String.isNotBlank(accessToken)
                && expiresAt != null
                && expiresAt > Datetime.now();
        }
    }

    /**
     * Returns a usable token, minting a new one only when the caches miss or the cached
     * token is inside its safety window.
     */
    public static Token getToken() {
        if (transactionToken != null && transactionToken.isUsable()) {
            return transactionToken;
        }
        Token cached = readFromPlatformCache();
        if (cached != null && cached.isUsable()) {
            transactionToken = cached;
            return cached;
        }
        Token fresh = requestToken();
        transactionToken = fresh;
        writeToPlatformCache(fresh);
        return fresh;
    }

    /** Drops cached tokens. Called after a 401 so the next attempt re-authenticates. */
    public static void invalidate() {
        transactionToken = null;
        try {
            Cache.Org.getPartition(CACHE_PARTITION).remove(CACHE_KEY);
        } catch (Exception ignored) {
            // Platform Cache not provisioned — resetting the static cache above is sufficient.
        }
    }

    private static Token requestToken() {
        HttpRequest req = new HttpRequest();
        // The External Credential behind this Named Credential supplies client_id and
        // client_secret, so no secret is ever stored in source or in a custom setting.
        req.setEndpoint('callout:SFMC_Auth/v2/token');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(20000);
        req.setBody(JSON.serialize(new Map<String, Object>{ 'grant_type' => 'client_credentials' }));

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            throw new ConsentCenterException(
                'Marketing Cloud authentication failed (HTTP ' + res.getStatusCode() + '): ' + res.getBody()
            );
        }

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        Token t = new Token();
        t.accessToken = (String) body.get('access_token');
        t.restInstanceUrl = (String) body.get('rest_instance_url');
        Integer expiresIn = body.get('expires_in') == null ? 1200 : Integer.valueOf(body.get('expires_in'));
        t.expiresAt = Datetime.now().addSeconds(Math.max(expiresIn - EXPIRY_SAFETY_WINDOW_SECONDS, 60));

        if (String.isBlank(t.accessToken)) {
            throw new ConsentCenterException('Marketing Cloud returned a token response with no access_token.');
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
            Integer ttlSeconds = Math.max(
                (Integer) ((t.expiresAt.getTime() - Datetime.now().getTime()) / 1000),
                60
            );
            Cache.Org.getPartition(CACHE_PARTITION).put(CACHE_KEY, JSON.serialize(t), ttlSeconds);
        } catch (Exception ignored) {
            // Best effort only.
        }
    }
}
