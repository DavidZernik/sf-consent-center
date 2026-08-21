/**
 * Trigger logic for Consent_Preference__c.
 *
 * Design notes worth stating, because they are the parts that go wrong at scale:
 *
 *   - Every method takes collections. Nothing here queries or DMLs inside a loop, so the
 *     behaviour is identical for 1 record and for a 10,000-record data load.
 *   - A static bypass exists so bulk migrations (the Informatica staging load, for one) can
 *     suppress downstream side effects and re-run them deliberately afterwards.
 *   - after-update only enqueues a Marketing Cloud push when a field that Marketing Cloud
 *     actually cares about changed. Without that check, every touch of the record — including
 *     the sync job writing back its own status — would re-queue another sync and loop forever.
 */
public with sharing class ConsentPreferenceTriggerHandler {
    /** Set by data loads that will re-sync explicitly afterwards. */
    public static Boolean bypass = false;

    /** Guards against a handler re-entering itself within one transaction. */
    private static Boolean isRunning = false;

    public static void run(
        System.TriggerOperation operation,
        List<Consent_Preference__c> newRecords,
        Map<Id, Consent_Preference__c> oldMap
    ) {
        if (bypass || isRunning) {
            return;
        }
        try {
            isRunning = true;
            switch on operation {
                when BEFORE_INSERT {
                    stampExternalKeys(newRecords);
                    defaultAuditFields(newRecords, null);
                }
                when BEFORE_UPDATE {
                    defaultAuditFields(newRecords, oldMap);
                }
                when AFTER_INSERT {
                    enqueueSync(newRecords, null);
                }
                when AFTER_UPDATE {
                    enqueueSync(newRecords, oldMap);
                }
                when else {
                    // No behaviour defined for the remaining contexts.
                }
            }
        } finally {
            isRunning = false;
        }
    }

    /**
     * Builds the composite external key used by every inbound integration.
     *
     * Doing this in before-insert rather than asking callers to supply it means an ETL job, the
     * REST endpoint and a hand-typed record all end up with the same key format, which is what
     * makes upsert-by-external-id safe.
     */
    @TestVisible
    private static void stampExternalKeys(List<Consent_Preference__c> records) {
        for (Consent_Preference__c record : records) {
            if (String.isBlank(record.External_Key__c) && record.Contact__c != null) {
                record.External_Key__c = record.Contact__c + '-' + record.Channel__c;
            }
        }
    }

    /**
     * Keeps Last_Changed__c honest: it moves only when the opt-in value actually moves.
     *
     * A field that updates on every save is useless for answering "when did this person last
     * change their mind", which is the only question it exists to answer.
     */
    @TestVisible
    private static void defaultAuditFields(
        List<Consent_Preference__c> records,
        Map<Id, Consent_Preference__c> oldMap
    ) {
        Datetime now = Datetime.now();
        for (Consent_Preference__c record : records) {
            Boolean optInChanged = oldMap == null
                || oldMap.get(record.Id) == null
                || oldMap.get(record.Id).Opt_In__c != record.Opt_In__c;

            if (optInChanged) {
                record.Last_Changed__c = now;
            }
            if (String.isBlank(record.Consent_Source__c)) {
                record.Consent_Source__c = 'Unspecified';
            }
            if (record.Sync_Attempts__c == null) {
                record.Sync_Attempts__c = 0;
            }
        }
    }

    /**
     * Queues a Marketing Cloud push for records whose marketing-relevant fields changed.
     *
     * The recursion guard is the important part. The sync job writes Sync_Status__c back onto
     * this object; if that write re-triggered a sync, the org would queue jobs until it hit the
     * async limit.
     */
    @TestVisible
    private static void enqueueSync(
        List<Consent_Preference__c> records,
        Map<Id, Consent_Preference__c> oldMap
    ) {
        List<Id> toSync = new List<Id>();
        for (Consent_Preference__c record : records) {
            if (oldMap == null) {
                toSync.add(record.Id);
                continue;
            }
            Consent_Preference__c previous = oldMap.get(record.Id);
            Boolean marketingRelevantChange =
                previous.Opt_In__c != record.Opt_In__c
                || previous.Consent_Source__c != record.Consent_Source__c;

            if (marketingRelevantChange) {
                toSync.add(record.Id);
            }
        }

        if (toSync.isEmpty()) {
            return;
        }
        // Queueable jobs cannot be chained from a trigger inside a batch context; the nightly
        // backfill picks those rows up from their Pending status instead.
        if (System.isBatch() || System.isFuture() || Limits.getLimitQueueableJobs() - Limits.getQueueableJobs() <= 0) {
            return;
        }
        SfmcSyncQueueable.enqueueAll(toSync);
    }
}
