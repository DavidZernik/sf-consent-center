/**
 * Nightly backfill for consent rows that never made it to Marketing Cloud.
 *
 * Stateful so the run can report a single summary rather than one email per chunk. The batch
 * size is deliberately capped to SfmcClient.MAX_ROWS_PER_REQUEST at schedule time so each
 * execute() maps to exactly one callout and stays inside the 100-callout governor limit.
 */
public with sharing class ConsentSyncBatch implements Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful, Schedulable {
    private static final String DE_EXTERNAL_KEY = 'Consent_Preferences';

    @TestVisible
    private Integer processed = 0;
    @TestVisible
    private Integer failed = 0;

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id, Contact__c, Contact__r.Email, Channel__c, Opt_In__c,
                   Consent_Source__c, Last_Changed__c, Sync_Status__c, Sync_Attempts__c
            FROM Consent_Preference__c
            WHERE Sync_Status__c IN ('Pending', 'Failed')
              AND Sync_Attempts__c < :SfmcSyncQueueable.MAX_ATTEMPTS
            ORDER BY Last_Changed__c ASC NULLS FIRST
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Consent_Preference__c> scope) {
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        for (Consent_Preference__c pref : scope) {
            rows.add(SfmcClient.toRow(pref));
        }

        SfmcClient.SyncResponse response = new SfmcClient().upsertRows(DE_EXTERNAL_KEY, rows);

        List<Consent_Preference__c> updates = new List<Consent_Preference__c>();
        List<Sync_Log__c> logs = new List<Sync_Log__c>();
        for (Consent_Preference__c pref : scope) {
            Integer nextAttempt = (pref.Sync_Attempts__c == null ? 0 : pref.Sync_Attempts__c.intValue()) + 1;
            updates.add(new Consent_Preference__c(
                Id = pref.Id,
                Sync_Status__c = response.success ? 'Synced' : 'Failed',
                Sync_Attempts__c = nextAttempt,
                Last_Sync_Error__c = response.success ? null : response.errorMessage
            ));
            logs.add(new Sync_Log__c(
                Consent_Preference__c = pref.Id,
                Status__c = response.success ? 'Success' : 'Failed',
                Attempt__c = nextAttempt,
                Data_Extension_Key__c = DE_EXTERNAL_KEY,
                Status_Code__c = response.statusCode,
                Error_Message__c = response.errorMessage,
                Duration_Ms__c = response.durationMs,
                Processed_At__c = Datetime.now()
            ));
        }

        // Partial success is allowed: one malformed row must not discard the whole chunk.
        Database.update(updates, false, AccessLevel.SYSTEM_MODE);
        Database.insert(logs, false, AccessLevel.SYSTEM_MODE);

        if (response.success) {
            processed += scope.size();
        } else {
            failed += scope.size();
        }
    }

    public void finish(Database.BatchableContext bc) {
        System.debug(LoggingLevel.INFO, 'ConsentSyncBatch finished. Synced=' + processed + ' Failed=' + failed);
    }

    /** Scheduled entry point: sf apex run -> System.schedule('Consent sync', cron, new ConsentSyncBatch()); */
    public void execute(SchedulableContext sc) {
        Database.executeBatch(new ConsentSyncBatch(), SfmcClient.MAX_ROWS_PER_REQUEST);
    }
}
