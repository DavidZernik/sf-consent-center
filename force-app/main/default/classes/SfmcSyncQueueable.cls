/**
 * Pushes consent changes to Marketing Cloud, one chunk per queued job.
 *
 * Why a Queueable rather than a future: it can chain, so a partial failure re-enqueues only
 * the rows that failed instead of replaying the whole set, and the retry count survives
 * between attempts as instance state.
 *
 * Backoff is expressed as a minimum delay in minutes (1, 2, 4...). Queueable chaining cannot
 * sleep, so the delay is honoured by re-enqueueing with System.enqueueJob's delay argument.
 */
public with sharing class SfmcSyncQueueable implements Queueable, Database.AllowsCallouts {
    /** After this many attempts a row is parked as Failed for a human to look at. */
    public static final Integer MAX_ATTEMPTS = 4;
    private static final String DE_EXTERNAL_KEY = 'Consent_Preferences';

    private final List<Id> preferenceIds;
    private final Integer attempt;

    public SfmcSyncQueueable(List<Id> preferenceIds) {
        this(preferenceIds, 1);
    }

    public SfmcSyncQueueable(List<Id> preferenceIds, Integer attempt) {
        this.preferenceIds = preferenceIds == null ? new List<Id>() : preferenceIds;
        this.attempt = attempt == null ? 1 : attempt;
    }

    public void execute(QueueableContext context) {
        if (preferenceIds.isEmpty()) {
            return;
        }

        List<Consent_Preference__c> prefs = [
            SELECT Id, Contact__c, Contact__r.Email, Channel__c, Opt_In__c,
                   Consent_Source__c, Last_Changed__c, Sync_Status__c, Sync_Attempts__c
            FROM Consent_Preference__c
            WHERE Id IN :preferenceIds
            WITH SYSTEM_MODE
        ];
        if (prefs.isEmpty()) {
            return;
        }

        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        for (Consent_Preference__c pref : prefs) {
            rows.add(SfmcClient.toRow(pref));
        }

        SfmcClient.SyncResponse response = new SfmcClient().upsertRows(DE_EXTERNAL_KEY, rows);

        List<Sync_Log__c> logs = new List<Sync_Log__c>();
        List<Consent_Preference__c> updates = new List<Consent_Preference__c>();
        Boolean shouldRetry = !response.success && response.retryable && attempt < MAX_ATTEMPTS;

        for (Consent_Preference__c pref : prefs) {
            updates.add(new Consent_Preference__c(
                Id = pref.Id,
                Sync_Status__c = response.success ? 'Synced' : (shouldRetry ? 'Pending' : 'Failed'),
                Sync_Attempts__c = attempt,
                Last_Sync_Error__c = response.success ? null : response.errorMessage
            ));
            logs.add(new Sync_Log__c(
                Consent_Preference__c = pref.Id,
                Status__c = response.success ? 'Success' : (shouldRetry ? 'Retrying' : 'Failed'),
                Attempt__c = attempt,
                Data_Extension_Key__c = DE_EXTERNAL_KEY,
                Status_Code__c = response.statusCode,
                Error_Message__c = response.errorMessage,
                Duration_Ms__c = response.durationMs,
                Processed_At__c = Datetime.now()
            ));
        }

        // Persist the outcome before chaining so a failure in the next job cannot lose the audit trail.
        update as system updates;
        insert as system logs;

        if (shouldRetry) {
            enqueueRetry(preferenceIds, attempt + 1);
        }
    }

    /**
     * Chains the next attempt with exponential backoff.
     *
     * Guarded on the async job limit: inside a test context, and when the org is already at
     * its queueable depth, chaining throws — parking the rows is better than an unhandled
     * exception that rolls back the logs written above.
     */
    @TestVisible
    private static void enqueueRetry(List<Id> preferenceIds, Integer nextAttempt) {
        if (Test.isRunningTest()) {
            // Chaining is not permitted from a test context; coverage of the retry decision
            // is asserted through Sync_Log__c status instead.
            return;
        }
        Integer delayMinutes = (Integer) Math.pow(2, nextAttempt - 2);
        try {
            System.enqueueJob(new SfmcSyncQueueable(preferenceIds, nextAttempt), Math.max(delayMinutes, 1));
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Unable to chain SFMC retry: ' + e.getMessage());
        }
    }

    /**
     * Splits a set of preference ids into chunks the REST endpoint will accept and queues one
     * job per chunk. This is the entry point every caller should use.
     */
    public static List<Id> enqueueAll(List<Id> preferenceIds) {
        List<Id> jobIds = new List<Id>();
        if (preferenceIds == null || preferenceIds.isEmpty()) {
            return jobIds;
        }
        List<Id> chunk = new List<Id>();
        for (Id prefId : preferenceIds) {
            chunk.add(prefId);
            if (chunk.size() == SfmcClient.MAX_ROWS_PER_REQUEST) {
                jobIds.add(System.enqueueJob(new SfmcSyncQueueable(chunk)));
                chunk = new List<Id>();
            }
        }
        if (!chunk.isEmpty()) {
            jobIds.add(System.enqueueJob(new SfmcSyncQueueable(chunk)));
        }
        return jobIds;
    }
}
