/**
 * Data Cloud boundary for the Consent Center UI.
 *
 * The problem this solves: a single human being usually exists several times in CRM, a web
 * lead, a POS record, a support contact. Identity Resolution collapses those into one Unified
 * Individual. Consent has to be answered at that unified level, because "did this person opt
 * out of email" is a question about the person, not about whichever record you happened to open.
 *
 * The resolution rule applied here is most-restrictive-wins: if ANY source record says opted
 * out, the unified answer is opted out. That is the defensible reading of consent law and it is
 * also the only rule that fails safe when source systems disagree.
 *
 * DMO and Calculated Insight API names vary per org. The names below follow the standard Data
 * Cloud model; adjust CONSENT_DMO and ENGAGEMENT_CI for your own data space.
 */
public with sharing class DataCloudService {
    private static final String UNIFIED_INDIVIDUAL_DMO = 'UnifiedIndividual__dlm';
    private static final String IDENTITY_LINK_DMO = 'IndividualIdentityLink__dlm';
    private static final String CONSENT_DMO = 'ssot__ContactPointConsent__dlm';
    private static final String EMAIL_DMO = 'ssot__ContactPointEmail__dlm';
    private static final String ENGAGEMENT_CI = 'Engagement_Score__cio';
    private static final String DIAGNOSTICS_PERMISSION = 'View_Data_Cloud_Diagnostics';

    private static final Integer DEFAULT_ROWS = 50;
    private static final Integer MAX_ROWS = 200;

    /* ---------------------------------------------------------------------- DTOs */

    /** One CRM record that resolved into a unified profile. */
    public class SourceRecord {
        @AuraEnabled public String sourceRecordId;
        @AuraEnabled public String sourceSystem;
        @AuraEnabled public String name;
        @AuraEnabled public String email;
        @AuraEnabled public Decimal matchConfidence;
        @AuraEnabled public Datetime lastModified;
    }

    /** Consent as recorded against one contact point, before resolution. */
    public class SourceConsent {
        @AuraEnabled public String sourceRecordId;
        @AuraEnabled public String sourceSystem;
        @AuraEnabled public String channel;
        @AuraEnabled public Boolean optIn;
        @AuraEnabled public Datetime capturedAt;
    }

    /** The resolved answer for one channel, plus the reasoning behind it. */
    public class ResolvedChannel {
        @AuraEnabled public String channel;
        @AuraEnabled public Boolean optIn;
        @AuraEnabled public String reason;
        @AuraEnabled public Integer sourcesAgreeing;
        @AuraEnabled public Integer sourcesTotal;
        @AuraEnabled public Boolean isConflicted;
    }

    public class EngagementInsight {
        @AuraEnabled public Decimal score;
        @AuraEnabled public String band;
        @AuraEnabled public Datetime lastEngagementAt;
        @AuraEnabled public Integer emailOpens90d;
        @AuraEnabled public Integer clicks90d;
    }

    /**
     * One Data Cloud query, surfaced so the console can show what was actually run.
     *
     * The statement itself is withheld unless the running user holds the diagnostics custom
     * permission. Query text names every DMO and field the org models, which is schema detail
     * a general console user has no reason to receive.
     */
    public class QueryTrace {
        @AuraEnabled public String purpose;
        @AuraEnabled public String dmo;
        @AuraEnabled public Integer rowCount;
        @AuraEnabled public Long durationMs;
        @AuraEnabled public String sql;
    }

    public class UnifiedProfile {
        @AuraEnabled public String unifiedId;
        @AuraEnabled public String name;
        @AuraEnabled public String primaryEmail;
        @AuraEnabled public List<SourceRecord> sources;
        @AuraEnabled public List<SourceConsent> sourceConsents;
        @AuraEnabled public List<ResolvedChannel> resolvedConsent;
        @AuraEnabled public EngagementInsight engagement;
        @AuraEnabled public Long queryDurationMs;
        @AuraEnabled public List<QueryTrace> queries = new List<QueryTrace>();
    }

    /* ------------------------------------------------------------------ Entry points */

    /**
     * Full unified picture for one CRM contact.
     *
     * Three Data Cloud queries, not one join: the identity graph, the consent rows and the
     * Calculated Insight live in different subject areas, and Data Cloud charges by data
     * processed. Three tight queries cost less than one wide join across all three.
     */
    @AuraEnabled(cacheable=true)
    public static UnifiedProfile getUnifiedProfile(Id contactId) {
        if (contactId == null) {
            throw new AuraHandledException('A contact is required.');
        }
        try {
            DataCloudClient client = new DataCloudClient();
            Long totalMs = 0;

            // 1. Resolve the CRM contact to its unified individual and pull the identity graph.
            String linkSql =
                'SELECT link.UnifiedRecordId__c, link.SourceRecordId__c, link.SourceSystemName__c, ' +
                'link.MatchConfidence__c, ui.ssot__FirstName__c, ui.ssot__LastName__c, ' +
                'email.ssot__EmailAddress__c, link.ssot__LastModifiedDate__c ' +
                'FROM ' + DataCloudQuery.identifier(IDENTITY_LINK_DMO) + ' link ' +
                'JOIN ' + DataCloudQuery.identifier(UNIFIED_INDIVIDUAL_DMO) + ' ui ' +
                'ON link.UnifiedRecordId__c = ui.ssot__Id__c ' +
                'LEFT JOIN ' + DataCloudQuery.identifier(EMAIL_DMO) + ' email ' +
                'ON email.ssot__PartyId__c = ui.ssot__Id__c ' +
                'WHERE link.UnifiedRecordId__c IN (' +
                '  SELECT UnifiedRecordId__c FROM ' + DataCloudQuery.identifier(IDENTITY_LINK_DMO) +
                '  WHERE SourceRecordId__c = ' + DataCloudQuery.literal(String.valueOf(contactId)) +
                ') LIMIT ' + DataCloudQuery.safeLimit(null, DEFAULT_ROWS, MAX_ROWS);

            DataCloudClient.QueryResult linkResult = client.query(linkSql);
            totalMs += linkResult.durationMs;
            QueryTrace linkTrace = trace('Identity graph', IDENTITY_LINK_DMO, linkSql, linkResult);

            if (linkResult.rows.isEmpty()) {
                throw new ConsentCenterException(
                    'No unified profile found for this contact. Identity Resolution may not have run yet.'
                );
            }

            UnifiedProfile profile = buildProfileShell(linkResult.rows);
            profile.queries.add(linkTrace);

            // 2. Consent rows for every source record in the graph.
            List<String> sourceIds = new List<String>();
            for (SourceRecord source : profile.sources) {
                sourceIds.add(source.sourceRecordId);
            }
            String consentSql =
                'SELECT ssot__PartyIdentificationId__c, ssot__ContactPointType__c, ' +
                'ssot__ConsentStatus__c, ssot__EffectiveFromDate__c, ssot__DataSourceName__c ' +
                'FROM ' + DataCloudQuery.identifier(CONSENT_DMO) +
                ' WHERE ssot__PartyIdentificationId__c IN ' + DataCloudQuery.inList(sourceIds) +
                ' LIMIT ' + MAX_ROWS;

            DataCloudClient.QueryResult consentResult = client.query(consentSql);
            totalMs += consentResult.durationMs;
            profile.queries.add(trace('Consent by contact point', CONSENT_DMO, consentSql, consentResult));
            profile.sourceConsents = mapSourceConsents(consentResult.rows);
            profile.resolvedConsent = resolveConsent(profile.sourceConsents);

            // 3. Engagement Calculated Insight, keyed on the unified id.
            String insightSql =
                'SELECT Engagement_Score__c, Last_Engagement_Date__c, Email_Opens_90d__c, Clicks_90d__c ' +
                'FROM ' + DataCloudQuery.identifier(ENGAGEMENT_CI) +
                ' WHERE UnifiedIndividualId__c = ' + DataCloudQuery.literal(profile.unifiedId) +
                ' LIMIT 1';

            DataCloudClient.QueryResult insightResult = client.query(insightSql);
            totalMs += insightResult.durationMs;
            profile.queries.add(trace('Engagement Calculated Insight', ENGAGEMENT_CI, insightSql, insightResult));
            profile.engagement = mapEngagement(insightResult.rows);

            profile.queryDurationMs = totalMs;
            return profile;
        } catch (Exception e) {
            throw asUiError(e, 'Unable to load the unified profile.');
        }
    }

    /* --------------------------------------------------------------- Query tracing */

    /** Cached per transaction: the permission cannot change mid-request. */
    @TestVisible
    private static Boolean diagnosticsAllowed;

    private static Boolean canSeeSql() {
        if (diagnosticsAllowed == null) {
            diagnosticsAllowed = FeatureManagement.checkPermission(DIAGNOSTICS_PERMISSION);
        }
        return diagnosticsAllowed;
    }

    private static QueryTrace trace(String purpose, String dmo, String sql, DataCloudClient.QueryResult result) {
        QueryTrace t = new QueryTrace();
        t.purpose = purpose;
        t.dmo = dmo;
        t.rowCount = result.rowCount;
        t.durationMs = result.durationMs;
        t.sql = canSeeSql() ? sql : null;
        return t;
    }

    /* --------------------------------------------------------------- Domain logic */

    /**
     * Collapses per-source consent into one answer per channel.
     *
     * Most-restrictive-wins: a single opt-out anywhere in the graph makes the unified answer
     * opted out. A channel where sources disagree is flagged as conflicted so the UI can show
     * that the answer was contested rather than unanimous. That distinction is exactly what an
     * auditor asks about.
     *
     * Public and static with no callouts so it can be unit tested directly.
     */
    @TestVisible
    public static List<ResolvedChannel> resolveConsent(List<SourceConsent> sourceConsents) {
        Map<String, List<SourceConsent>> byChannel = new Map<String, List<SourceConsent>>();
        for (SourceConsent consent : sourceConsents) {
            if (!byChannel.containsKey(consent.channel)) {
                byChannel.put(consent.channel, new List<SourceConsent>());
            }
            byChannel.get(consent.channel).add(consent);
        }

        List<ResolvedChannel> resolved = new List<ResolvedChannel>();
        for (String channel : byChannel.keySet()) {
            List<SourceConsent> entries = byChannel.get(channel);
            Integer optedIn = 0;
            Integer optedOut = 0;
            for (SourceConsent entry : entries) {
                if (entry.optIn == true) {
                    optedIn++;
                } else {
                    optedOut++;
                }
            }

            ResolvedChannel channelResult = new ResolvedChannel();
            channelResult.channel = channel;
            channelResult.sourcesTotal = entries.size();
            channelResult.isConflicted = optedIn > 0 && optedOut > 0;
            channelResult.optIn = optedOut == 0;
            channelResult.sourcesAgreeing = channelResult.optIn ? optedIn : optedOut;

            if (channelResult.isConflicted) {
                channelResult.reason =
                    optedOut + ' of ' + entries.size() + ' sources recorded an opt-out. ' +
                    'Most restrictive wins, so the unified profile is opted out.';
            } else {
                channelResult.reason = describeAgreement(entries.size(), channelResult.optIn);
            }
            resolved.add(channelResult);
        }
        return resolved;
    }

    /**
     * Phrases unanimous agreement.
     *
     * Split out because "All 1 sources agree" reads as a bug to anyone looking at a compliance
     * screen, and a single-source profile is the common case, not an edge case.
     */
    @TestVisible
    private static String describeAgreement(Integer sourceCount, Boolean optIn) {
        String position = optIn ? 'opt-in' : 'opt-out';
        if (sourceCount == 1) {
            return 'The only source on record is ' + position + '.';
        }
        return 'All ' + sourceCount + ' sources agree on ' + position + '.';
    }

    /* -------------------------------------------------------------------- Mapping */

    private static UnifiedProfile buildProfileShell(List<Map<String, Object>> rows) {
        UnifiedProfile profile = new UnifiedProfile();
        profile.sources = new List<SourceRecord>();
        profile.sourceConsents = new List<SourceConsent>();
        profile.resolvedConsent = new List<ResolvedChannel>();

        Set<String> seenSourceIds = new Set<String>();
        for (Map<String, Object> row : rows) {
            if (profile.unifiedId == null) {
                profile.unifiedId = str(row.get('UnifiedRecordId__c'));
                profile.name = (str(row.get('ssot__FirstName__c')) + ' ' + str(row.get('ssot__LastName__c'))).trim();
                profile.primaryEmail = str(row.get('ssot__EmailAddress__c'));
            }
            String sourceId = str(row.get('SourceRecordId__c'));
            // The LEFT JOIN on email fans rows out; only the first row per source is the source.
            if (String.isBlank(sourceId) || seenSourceIds.contains(sourceId)) {
                continue;
            }
            seenSourceIds.add(sourceId);

            SourceRecord source = new SourceRecord();
            source.sourceRecordId = sourceId;
            source.sourceSystem = str(row.get('SourceSystemName__c'));
            source.name = profile.name;
            source.email = str(row.get('ssot__EmailAddress__c'));
            source.matchConfidence = dec(row.get('MatchConfidence__c'));
            source.lastModified = dt(row.get('ssot__LastModifiedDate__c'));
            profile.sources.add(source);
        }
        return profile;
    }

    private static List<SourceConsent> mapSourceConsents(List<Map<String, Object>> rows) {
        List<SourceConsent> consents = new List<SourceConsent>();
        for (Map<String, Object> row : rows) {
            SourceConsent consent = new SourceConsent();
            consent.sourceRecordId = str(row.get('ssot__PartyIdentificationId__c'));
            consent.sourceSystem = str(row.get('ssot__DataSourceName__c'));
            consent.channel = str(row.get('ssot__ContactPointType__c'));
            // Data Cloud stores consent as a status string, not a boolean.
            consent.optIn = 'OptIn'.equalsIgnoreCase(str(row.get('ssot__ConsentStatus__c')));
            consent.capturedAt = dt(row.get('ssot__EffectiveFromDate__c'));
            consents.add(consent);
        }
        return consents;
    }

    private static EngagementInsight mapEngagement(List<Map<String, Object>> rows) {
        EngagementInsight insight = new EngagementInsight();
        if (rows.isEmpty()) {
            insight.score = 0;
            insight.band = 'No data';
            return insight;
        }
        Map<String, Object> row = rows[0];
        insight.score = dec(row.get('Engagement_Score__c'));
        insight.lastEngagementAt = dt(row.get('Last_Engagement_Date__c'));
        insight.emailOpens90d = intOf(row.get('Email_Opens_90d__c'));
        insight.clicks90d = intOf(row.get('Clicks_90d__c'));
        insight.band = bandFor(insight.score);
        return insight;
    }

    @TestVisible
    private static String bandFor(Decimal score) {
        if (score == null) return 'No data';
        if (score >= 75) return 'Highly engaged';
        if (score >= 40) return 'Engaged';
        if (score > 0) return 'At risk';
        return 'Dormant';
    }

    /* ------------------------------------------------------------------- Coercion */

    private static String str(Object value) {
        return value == null ? '' : String.valueOf(value);
    }

    private static Decimal dec(Object value) {
        if (value == null) return null;
        try {
            return Decimal.valueOf(String.valueOf(value));
        } catch (Exception e) {
            return null;
        }
    }

    private static Integer intOf(Object value) {
        Decimal d = dec(value);
        return d == null ? null : d.intValue();
    }

    private static Datetime dt(Object value) {
        if (value == null) return null;
        try {
            // Data Cloud returns ISO-8601; Datetime.valueOfGmt wants a space separator.
            return (Datetime) JSON.deserialize('"' + String.valueOf(value) + '"', Datetime.class);
        } catch (Exception e) {
            return null;
        }
    }

    private static AuraHandledException asUiError(Exception e, String fallback) {
        System.debug(LoggingLevel.ERROR, e.getTypeName() + ': ' + e.getMessage());
        String message = (e instanceof ConsentCenterException || e instanceof AuraHandledException)
            ? e.getMessage()
            : fallback;
        AuraHandledException uiError = new AuraHandledException(message);
        uiError.setMessage(message);
        return uiError;
    }
}
