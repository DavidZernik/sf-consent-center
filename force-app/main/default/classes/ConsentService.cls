/**
 * The @AuraEnabled boundary for the Consent Center UI.
 *
 * Three rules hold everywhere in this class:
 *   1. Nothing but this layer throws AuraHandledException. Internals throw typed exceptions.
 *   2. Every method is bulk-safe, no SOQL or DML inside a loop, ever.
 *   3. DTOs are explicit rather than returning SObjects, so the wire contract is stable even
 *      if the underlying fields are renamed, and so no field the UI shouldn't see leaks out.
 *
 * The JSON these methods return is the exact contract the browser demo replays; see
 * demo/src/mocks/apex/ in this repository.
 */
public with sharing class ConsentService {
    private static final ConsentSelector SELECTOR = new ConsentSelector();
    private static final Set<String> VALID_CHANNELS = new Set<String>{ 'Email', 'SMS', 'Push', 'Direct Mail' };

    /* ---------------------------------------------------------------------- DTOs */

    public class ConsentSummary {
        @AuraEnabled public Id preferenceId;
        @AuraEnabled public Id contactId;
        @AuraEnabled public String contactName;
        @AuraEnabled public String email;
        @AuraEnabled public String channel;
        @AuraEnabled public Boolean optIn;
        @AuraEnabled public String consentSource;
        @AuraEnabled public String lifecycleStage;
        @AuraEnabled public Datetime lastChanged;
        @AuraEnabled public String syncStatus;
    }

    public class ChannelPreference {
        @AuraEnabled public Id preferenceId;
        @AuraEnabled public String channel;
        @AuraEnabled public Boolean optIn;
        @AuraEnabled public String consentSource;
        @AuraEnabled public Datetime lastChanged;
        @AuraEnabled public String syncStatus;
    }

    public class HistoryEntry {
        @AuraEnabled public Id historyId;
        @AuraEnabled public String channel;
        @AuraEnabled public String previousValue;
        @AuraEnabled public String newValue;
        @AuraEnabled public String changedByName;
        @AuraEnabled public String changeSource;
        @AuraEnabled public Datetime changedAt;
    }

    public class ConsentDetail {
        @AuraEnabled public Id contactId;
        @AuraEnabled public String contactName;
        @AuraEnabled public String email;
        @AuraEnabled public String lifecycleStage;
        @AuraEnabled public List<ChannelPreference> preferences;
        @AuraEnabled public List<HistoryEntry> history;
    }

    public class SyncLogView {
        @AuraEnabled public Id logId;
        @AuraEnabled public String contactName;
        @AuraEnabled public String channel;
        @AuraEnabled public String status;
        @AuraEnabled public Integer attempt;
        @AuraEnabled public String dataExtensionKey;
        @AuraEnabled public Integer statusCode;
        @AuraEnabled public String errorMessage;
        @AuraEnabled public Integer durationMs;
        @AuraEnabled public Datetime processedAt;
    }

    public class RetryResult {
        @AuraEnabled public Integer queued;
        @AuraEnabled public Integer skipped;
        @AuraEnabled public String message;
    }

    /* ------------------------------------------------------------------- Queries */

    /**
     * Rows for the consent list view.
     *
     * cacheable=true so the client-side Lightning cache can serve repeat renders without a
     * round trip; that is only sound because this method has no side effects.
     */
    @AuraEnabled(cacheable=true)
    public static List<ConsentSummary> getConsentSummaries(String searchTerm, String channel) {
        try {
            List<ConsentSummary> results = new List<ConsentSummary>();
            for (Consent_Preference__c pref : SELECTOR.searchSummaries(searchTerm, channel, 200)) {
                ConsentSummary s = new ConsentSummary();
                s.preferenceId = pref.Id;
                s.contactId = pref.Contact__c;
                s.contactName = pref.Contact__r == null ? null : pref.Contact__r.Name;
                s.email = pref.Contact__r == null ? null : pref.Contact__r.Email;
                s.channel = pref.Channel__c;
                s.optIn = pref.Opt_In__c == true;
                s.consentSource = pref.Consent_Source__c;
                s.lifecycleStage = pref.Lifecycle_Stage__c;
                s.lastChanged = pref.Last_Changed__c;
                s.syncStatus = pref.Sync_Status__c;
                results.add(s);
            }
            return results;
        } catch (Exception e) {
            throw asUiError(e, 'Unable to load consent records.');
        }
    }

    /** Full preference + audit picture for one contact. */
    @AuraEnabled(cacheable=true)
    public static ConsentDetail getConsentDetail(Id contactId) {
        if (contactId == null) {
            throw new AuraHandledException('A contact is required.');
        }
        try {
            return buildDetail(contactId);
        } catch (Exception e) {
            throw asUiError(e, 'Unable to load consent detail.');
        }
    }

    /** Marketing Cloud sync activity for the operations console. */
    @AuraEnabled(cacheable=true)
    public static List<SyncLogView> getSyncLogs(String status) {
        try {
            List<SyncLogView> views = new List<SyncLogView>();
            for (Sync_Log__c log : SELECTOR.selectSyncLogs(status, 100)) {
                SyncLogView v = new SyncLogView();
                v.logId = log.Id;
                v.contactName = log.Consent_Preference__r == null || log.Consent_Preference__r.Contact__r == null
                    ? null
                    : log.Consent_Preference__r.Contact__r.Name;
                v.channel = log.Consent_Preference__r == null ? null : log.Consent_Preference__r.Channel__c;
                v.status = log.Status__c;
                v.attempt = log.Attempt__c == null ? null : log.Attempt__c.intValue();
                v.dataExtensionKey = log.Data_Extension_Key__c;
                v.statusCode = log.Status_Code__c == null ? null : log.Status_Code__c.intValue();
                v.errorMessage = log.Error_Message__c;
                v.durationMs = log.Duration_Ms__c == null ? null : log.Duration_Ms__c.intValue();
                v.processedAt = log.Processed_At__c;
                views.add(v);
            }
            return views;
        } catch (Exception e) {
            throw asUiError(e, 'Unable to load sync activity.');
        }
    }

    /* ----------------------------------------------------------------- Mutations */

    /**
     * Applies a set of channel changes for one contact and queues the Marketing Cloud push.
     *
     * Not cacheable, and deliberately not annotated with (continuation). The callout is
     * handed to a Queueable so the user gets an immediate response and the sync is retried
     * independently of their session.
     *
     * @param contactId   Contact whose preferences are changing.
     * @param changesJson JSON array of {channel, optIn}, passed as a string because
     *                    Lightning cannot marshal a List of inner-class instances inbound.
     * @param source      Where the change originated, recorded on the audit trail.
     */
    @AuraEnabled
    public static ConsentDetail savePreferences(Id contactId, String changesJson, String source) {
        if (contactId == null) {
            throw new AuraHandledException('A contact is required.');
        }
        if (String.isBlank(changesJson)) {
            throw new AuraHandledException('No preference changes were supplied.');
        }

        SavePoint sp = Database.setSavepoint();
        try {
            List<ChannelPreference> requested =
                (List<ChannelPreference>) JSON.deserialize(changesJson, List<ChannelPreference>.class);
            validateChannels(requested);

            Map<String, Consent_Preference__c> existingByChannel = new Map<String, Consent_Preference__c>();
            for (Consent_Preference__c pref : SELECTOR.selectByContactIds(new Set<Id>{ contactId })) {
                existingByChannel.put(pref.Channel__c, pref);
            }

            List<Consent_Preference__c> toUpsert = new List<Consent_Preference__c>();
            List<Consent_History__c> auditTrail = new List<Consent_History__c>();
            String actorName = UserInfo.getName();
            Datetime now = Datetime.now();

            for (ChannelPreference change : requested) {
                Consent_Preference__c existing = existingByChannel.get(change.channel);
                Boolean previous = existing != null && existing.Opt_In__c == true;
                Boolean next = change.optIn == true;

                // Skip no-op changes so the audit trail records intent, not page saves.
                if (existing != null && previous == next) {
                    continue;
                }

                Consent_Preference__c record = existing == null
                    ? new Consent_Preference__c(Contact__c = contactId, Channel__c = change.channel)
                    : new Consent_Preference__c(Id = existing.Id);
                record.Opt_In__c = next;
                record.Consent_Source__c = String.isBlank(source) ? 'Service Console' : source;
                record.Last_Changed__c = now;
                record.Sync_Status__c = 'Pending';
                record.Sync_Attempts__c = 0;
                toUpsert.add(record);

                auditTrail.add(new Consent_History__c(
                    Contact__c = contactId,
                    Channel__c = change.channel,
                    Previous_Value__c = existing == null ? 'None' : (previous ? 'Opted In' : 'Opted Out'),
                    New_Value__c = next ? 'Opted In' : 'Opted Out',
                    Changed_By_Name__c = actorName,
                    Change_Source__c = String.isBlank(source) ? 'Service Console' : source,
                    Changed_At__c = now
                ));
            }

            if (!toUpsert.isEmpty()) {
                // USER_MODE: a user who cannot edit consent must not be able to, even though
                // this method is invoked from a component they can see.
                upsert as user toUpsert;
                insert as user auditTrail;
                SfmcSyncQueueable.enqueueAll(new List<Id>(new Map<Id, Consent_Preference__c>(toUpsert).keySet()));
            }

            return buildDetail(contactId);
        } catch (Exception e) {
            Database.rollback(sp);
            throw asUiError(e, 'Unable to save preferences.');
        }
    }

    /**
     * Re-queues failed sync log entries.
     *
     * Entries whose preference already synced are skipped rather than re-sent, so a stale
     * console left open overnight cannot cause duplicate writes into the Data Extension.
     */
    @AuraEnabled
    public static RetryResult retrySync(List<Id> logIds) {
        RetryResult result = new RetryResult();
        result.queued = 0;
        result.skipped = 0;

        if (logIds == null || logIds.isEmpty()) {
            result.message = 'Nothing selected to retry.';
            return result;
        }

        try {
            List<Sync_Log__c> logs = [
                SELECT Id, Consent_Preference__c, Consent_Preference__r.Sync_Status__c
                FROM Sync_Log__c
                WHERE Id IN :logIds
                WITH USER_MODE
            ];

            Set<Id> retryable = new Set<Id>();
            for (Sync_Log__c log : logs) {
                if (log.Consent_Preference__c == null || log.Consent_Preference__r.Sync_Status__c == 'Synced') {
                    result.skipped++;
                } else {
                    retryable.add(log.Consent_Preference__c);
                }
            }

            if (!retryable.isEmpty()) {
                List<Consent_Preference__c> reset = new List<Consent_Preference__c>();
                for (Id prefId : retryable) {
                    reset.add(new Consent_Preference__c(
                        Id = prefId,
                        Sync_Status__c = 'Pending',
                        Sync_Attempts__c = 0,
                        Last_Sync_Error__c = null
                    ));
                }
                update as user reset;
                SfmcSyncQueueable.enqueueAll(new List<Id>(retryable));
                result.queued = retryable.size();
            }

            result.message = result.queued + ' queued, ' + result.skipped + ' skipped.';
            return result;
        } catch (Exception e) {
            throw asUiError(e, 'Unable to queue the retry.');
        }
    }

    /* ------------------------------------------------------------------ Internals */

    private static ConsentDetail buildDetail(Id contactId) {
        Set<Id> ids = new Set<Id>{ contactId };
        List<Consent_Preference__c> prefs = SELECTOR.selectByContactIds(ids);
        List<Consent_History__c> history = SELECTOR.selectHistoryByContactIds(ids, 50);

        ConsentDetail detail = new ConsentDetail();
        detail.contactId = contactId;
        detail.preferences = new List<ChannelPreference>();
        detail.history = new List<HistoryEntry>();

        for (Consent_Preference__c pref : prefs) {
            if (detail.contactName == null && pref.Contact__r != null) {
                detail.contactName = pref.Contact__r.Name;
                detail.email = pref.Contact__r.Email;
            }
            if (detail.lifecycleStage == null) {
                detail.lifecycleStage = pref.Lifecycle_Stage__c;
            }
            ChannelPreference cp = new ChannelPreference();
            cp.preferenceId = pref.Id;
            cp.channel = pref.Channel__c;
            cp.optIn = pref.Opt_In__c == true;
            cp.consentSource = pref.Consent_Source__c;
            cp.lastChanged = pref.Last_Changed__c;
            cp.syncStatus = pref.Sync_Status__c;
            detail.preferences.add(cp);
        }

        for (Consent_History__c h : history) {
            HistoryEntry entry = new HistoryEntry();
            entry.historyId = h.Id;
            entry.channel = h.Channel__c;
            entry.previousValue = h.Previous_Value__c;
            entry.newValue = h.New_Value__c;
            entry.changedByName = h.Changed_By_Name__c;
            entry.changeSource = h.Change_Source__c;
            entry.changedAt = h.Changed_At__c;
            detail.history.add(entry);
        }

        return detail;
    }

    private static void validateChannels(List<ChannelPreference> requested) {
        if (requested == null || requested.isEmpty()) {
            throw new ConsentCenterException('No preference changes were supplied.');
        }
        for (ChannelPreference change : requested) {
            if (!VALID_CHANNELS.contains(change.channel)) {
                throw new ConsentCenterException('Unsupported channel: ' + change.channel);
            }
        }
    }

    /**
     * Translates any internal failure into something safe to render.
     *
     * AuraHandledException drops its message unless setMessage is called explicitly, which is
     * a well-known platform footgun and the reason this helper exists at all.
     */
    private static AuraHandledException asUiError(Exception e, String fallback) {
        System.debug(LoggingLevel.ERROR, e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString());
        String message = (e instanceof ConsentCenterException || e instanceof AuraHandledException)
            ? e.getMessage()
            : fallback;
        AuraHandledException uiError = new AuraHandledException(message);
        uiError.setMessage(message);
        return uiError;
    }
}
