/**
 * Promotes bulk-loaded consent rows from the staging object into live consent records.
 *
 * This is the batch half of the integration pattern (ConsentApiResource is the real-time half).
 * The shape is the standard one for an ETL tool such as Informatica:
 *
 *   1. The ETL job bulk-inserts into Consent_Staging__c. No triggers, no validation, no
 *      callouts — the load either lands or it does not, and it is fast.
 *   2. This batch validates, resolves match keys and promotes in chunks.
 *   3. Rows that fail are marked Failed with the reason ON the staging row, so the ETL team can
 *      query their own failures instead of asking someone to read a debug log.
 *
 * Two decisions here are the ones that matter at volume:
 *
 *   - The trigger handler is bypassed during promotion and the Marketing Cloud sync is queued
 *     once at the end. Without that, promoting 100,000 rows would enqueue 100,000 jobs.
 *   - Where several staged rows target the same contact and channel, the newest Captured_At__c
 *     wins. Bulk files routinely contain a person changing their mind twice; processing them in
 *     arbitrary order would apply whichever row happened to come last in the file.
 */
public with sharing class ConsentStagingBatch implements Database.Batchable<SObject>, Database.Stateful, Schedulable {
    private static final Set<String> VALID_CHANNELS = new Set<String>{ 'Email', 'SMS', 'Push', 'Direct Mail' };
    /** Values an upstream system might plausibly send for "yes". */
    private static final Set<String> TRUTHY = new Set<String>{ 'true', 'yes', 'y', '1', 'optin', 'opt-in', 'subscribed' };
    private static final Set<String> FALSY = new Set<String>{ 'false', 'no', 'n', '0', 'optout', 'opt-out', 'unsubscribed' };

    private final String batchId;

    @TestVisible
    private Integer promoted = 0;
    @TestVisible
    private Integer failed = 0;
    @TestVisible
    private Integer skipped = 0;

    /** Promotes every unprocessed row. */
    public ConsentStagingBatch() {
        this(null);
    }

    /** Promotes only the rows belonging to one ETL batch. */
    public ConsentStagingBatch(String batchId) {
        this.batchId = batchId;
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        if (String.isNotBlank(batchId)) {
            String scopedBatchId = batchId;
            return Database.getQueryLocator([
                SELECT Id, Batch_Id__c, Source_System__c, Email__c, Contact_External_Id__c,
                       Channel__c, Opt_In_Raw__c, Captured_At__c, Process_Status__c
                FROM Consent_Staging__c
                WHERE Process_Status__c = 'Unprocessed' AND Batch_Id__c = :scopedBatchId
                ORDER BY Captured_At__c ASC NULLS FIRST
            ]);
        }
        return Database.getQueryLocator([
            SELECT Id, Batch_Id__c, Source_System__c, Email__c, Contact_External_Id__c,
                   Channel__c, Opt_In_Raw__c, Captured_At__c, Process_Status__c
            FROM Consent_Staging__c
            WHERE Process_Status__c = 'Unprocessed'
            ORDER BY Captured_At__c ASC NULLS FIRST
        ]);
    }

    /** Outcome of the in-memory validation pass. */
    private class ValidationPass {
        Map<Id, String> errorByRowId = new Map<Id, String>();
        Set<String> emails = new Set<String>();
        Set<String> externalIds = new Set<String>();
    }

    /** The two match-key indexes, resolved in two queries regardless of scope size. */
    private class ContactIndex {
        Map<String, Id> byEmail = new Map<String, Id>();
        Map<String, Id> byExternalId = new Map<String, Id>();
    }

    /**
     * Validates every row in memory before a single query is spent.
     *
     * Separated from execute() so the shape rules can be read on their own, and so the query
     * pass below receives an explicit set of keys rather than reaching back into the loop.
     */
    private ValidationPass validateAll(List<Consent_Staging__c> scope) {
        ValidationPass pass = new ValidationPass();
        for (Consent_Staging__c row : scope) {
            String error = validateShape(row);
            if (error != null) {
                pass.errorByRowId.put(row.Id, error);
                continue;
            }
            if (String.isNotBlank(row.Email__c)) {
                pass.emails.add(row.Email__c.toLowerCase());
            }
            if (String.isNotBlank(row.Contact_External_Id__c)) {
                pass.externalIds.add(row.Contact_External_Id__c);
            }
        }
        return pass;
    }

    /** Resolves every match key in two queries, never one per row. */
    private ContactIndex resolveContacts(Set<String> emails, Set<String> externalIds) {
        ContactIndex index = new ContactIndex();
        if (!emails.isEmpty()) {
            for (Contact contact : [
                SELECT Id, Email FROM Contact WHERE Email IN :emails WITH SYSTEM_MODE LIMIT 10000
            ]) {
                index.byEmail.put(contact.Email.toLowerCase(), contact.Id);
            }
        }
        if (!externalIds.isEmpty()) {
            // Uses whichever external id field the org standardised on.
            for (Contact contact : [
                SELECT Id, ExternalId__c FROM Contact
                WHERE ExternalId__c IN :externalIds WITH SYSTEM_MODE LIMIT 10000
            ]) {
                index.byExternalId.put(contact.ExternalId__c, contact.Id);
            }
        }
        return index;
    }

    /** The surviving row per contact+channel, plus the rows it superseded. */
    private class WinnerSelection {
        Map<String, Consent_Staging__c> winnerByKey = new Map<String, Consent_Staging__c>();
        Map<String, Id> contactIdByKey = new Map<String, Id>();
        Set<Id> supersededRowIds = new Set<Id>();
    }

    /**
     * Picks one winning row per contact and channel, newest capture first.
     *
     * Bulk files routinely contain the same person changing their mind twice. Without this the
     * applied value depends on row order in the file, which is not a decision anybody made.
     *
     * Mutates errorByRowId deliberately: a row that resolves to no contact is a per-row failure,
     * and recording it here keeps that judgement next to the resolution that produced it.
     */
    private WinnerSelection selectWinners(
        List<Consent_Staging__c> scope,
        Map<Id, String> errorByRowId,
        ContactIndex contacts
    ) {
        WinnerSelection selection = new WinnerSelection();
        for (Consent_Staging__c row : scope) {
            if (errorByRowId.containsKey(row.Id)) {
                continue;
            }
            Id contactId = resolveContact(row, contacts.byEmail, contacts.byExternalId);
            if (contactId == null) {
                errorByRowId.put(row.Id, 'No contact matched the supplied email or external id.');
                continue;
            }

            String key = contactId + '|' + row.Channel__c;
            Consent_Staging__c incumbent = selection.winnerByKey.get(key);
            if (incumbent != null && !isNewer(row, incumbent)) {
                selection.supersededRowIds.add(row.Id);
                continue;
            }
            if (incumbent != null) {
                selection.supersededRowIds.add(incumbent.Id);
            }
            selection.winnerByKey.put(key, row);
            selection.contactIdByKey.put(key, contactId);
        }
        return selection;
    }

    /** Records to write, and the staging keys they correspond to, in matching order. */
    private class Promotion {
        List<Consent_Preference__c> toUpsert = new List<Consent_Preference__c>();
        List<Consent_History__c> auditTrail = new List<Consent_History__c>();
        List<String> promotedKeys = new List<String>();
    }

    /**
     * Turns the winning staging rows into preference and audit records.
     *
     * toUpsert and promotedKeys are built in lockstep: the DML result at index i belongs to the
     * staging row at promotedKeys[i], and that pairing is what lets a per-row failure be written
     * back onto the row that caused it.
     *
     * Rows already in the requested state are marked Skipped here rather than written, so a
     * re-run of the same file does not manufacture an audit trail of changes that never happened.
     */
    private Promotion buildPromotions(
        Map<String, Consent_Staging__c> winnerByKey,
        Map<String, Id> contactIdByKey,
        Map<String, Consent_Preference__c> existingByKey,
        Datetime now
    ) {
        Promotion promotion = new Promotion();
        for (String key : winnerByKey.keySet()) {
            Consent_Staging__c row = winnerByKey.get(key);
            Id contactId = contactIdByKey.get(key);
            Boolean next = TRUTHY.contains(row.Opt_In_Raw__c.trim().toLowerCase());

            Consent_Preference__c existing = existingByKey.get(key);
            Boolean previous = existing != null && existing.Opt_In__c == true;

            if (existing != null && previous == next) {
                // Already in the requested state — a no-op, not a failure.
                row.Process_Status__c = 'Skipped';
                row.Processed_At__c = now;
                skipped++;
                continue;
            }

            String source = String.isBlank(row.Source_System__c) ? 'Bulk Load' : row.Source_System__c;
            Datetime changedAt = row.Captured_At__c == null ? now : row.Captured_At__c;

            Consent_Preference__c record = existing == null
                ? new Consent_Preference__c(Contact__c = contactId, Channel__c = row.Channel__c)
                : new Consent_Preference__c(Id = existing.Id);
            record.Opt_In__c = next;
            record.Consent_Source__c = source;
            record.Last_Changed__c = changedAt;
            record.Sync_Status__c = 'Pending';
            record.Sync_Attempts__c = 0;

            promotion.toUpsert.add(record);
            promotion.promotedKeys.add(key);
            promotion.auditTrail.add(new Consent_History__c(
                Contact__c = contactId,
                Channel__c = row.Channel__c,
                Previous_Value__c = existing == null ? 'None' : (previous ? 'Opted In' : 'Opted Out'),
                New_Value__c = next ? 'Opted In' : 'Opted Out',
                Changed_By_Name__c = 'Integration User',
                Change_Source__c = source,
                Changed_At__c = changedAt
            ));
        }
        return promotion;
    }

    public void execute(Database.BatchableContext bc, List<Consent_Staging__c> scope) {
        Datetime now = Datetime.now();

        ValidationPass validation = validateAll(scope);
        Map<Id, String> errorByRowId = validation.errorByRowId;

        ContactIndex contacts = resolveContacts(validation.emails, validation.externalIds);

        WinnerSelection winners = selectWinners(scope, errorByRowId, contacts);
        Map<String, Consent_Staging__c> winnerByKey = winners.winnerByKey;
        Map<String, Id> contactIdByKey = winners.contactIdByKey;
        Set<Id> supersededRowIds = winners.supersededRowIds;

        // Promote the winners.
        Map<String, Consent_Preference__c> existingByKey = new Map<String, Consent_Preference__c>();
        if (!contactIdByKey.isEmpty()) {
            Set<Id> contactIds = new Set<Id>(contactIdByKey.values());
            for (Consent_Preference__c pref : [
                SELECT Id, Contact__c, Channel__c, Opt_In__c
                FROM Consent_Preference__c
                WHERE Contact__c IN :contactIds
                WITH SYSTEM_MODE
            ]) {
                existingByKey.put(pref.Contact__c + '|' + pref.Channel__c, pref);
            }
        }

        Promotion promotion = buildPromotions(winnerByKey, contactIdByKey, existingByKey, now);
        List<Consent_Preference__c> toUpsert = promotion.toUpsert;
        List<Consent_History__c> auditTrail = promotion.auditTrail;
        List<String> promotedKeys = promotion.promotedKeys;

        List<Id> promotedPreferenceIds = new List<Id>();
        if (!toUpsert.isEmpty()) {
            // Suppress the per-record sync; one bulk enqueue happens below instead.
            ConsentPreferenceTriggerHandler.bypass = true;
            try {
                List<Database.UpsertResult> upsertResults =
                    Database.upsert(toUpsert, false, AccessLevel.SYSTEM_MODE);

                for (Integer i = 0; i < upsertResults.size(); i++) {
                    Consent_Staging__c row = winnerByKey.get(promotedKeys[i]);
                    if (upsertResults[i].isSuccess()) {
                        row.Process_Status__c = 'Processed';
                        row.Error_Message__c = null;
                        promotedPreferenceIds.add(toUpsert[i].Id);
                        promoted++;
                    } else {
                        row.Process_Status__c = 'Failed';
                        row.Error_Message__c = truncate(upsertResults[i].getErrors()[0].getMessage(), 255);
                        failed++;
                    }
                    row.Processed_At__c = now;
                }
                Database.insert(auditTrail, false, AccessLevel.SYSTEM_MODE);
            } finally {
                // Reset in a finally block: leaving the bypass set would silently disable the
                // trigger for the rest of the transaction.
                ConsentPreferenceTriggerHandler.bypass = false;
            }
        }

        // Mark validation failures and superseded duplicates.
        for (Consent_Staging__c row : scope) {
            if (errorByRowId.containsKey(row.Id)) {
                row.Process_Status__c = 'Failed';
                row.Error_Message__c = errorByRowId.get(row.Id);
                row.Processed_At__c = now;
                failed++;
            } else if (supersededRowIds.contains(row.Id)) {
                row.Process_Status__c = 'Skipped';
                row.Error_Message__c = 'Superseded by a more recent capture for the same contact and channel.';
                row.Processed_At__c = now;
                skipped++;
            }
        }

        Database.update(scope, false, AccessLevel.SYSTEM_MODE);

        if (!promotedPreferenceIds.isEmpty()) {
            SfmcSyncQueueable.enqueueAll(promotedPreferenceIds);
        }
    }

    public void finish(Database.BatchableContext bc) {
        System.debug(LoggingLevel.INFO,
            'ConsentStagingBatch complete. Promoted=' + promoted + ' Skipped=' + skipped + ' Failed=' + failed);
    }

    public void execute(SchedulableContext sc) {
        Database.executeBatch(new ConsentStagingBatch(), 200);
    }

    /* ------------------------------------------------------------------ Internals */

    @TestVisible
    private static String validateShape(Consent_Staging__c row) {
        if (String.isBlank(row.Email__c) && String.isBlank(row.Contact_External_Id__c)) {
            return 'Either Email or Contact External Id is required.';
        }
        if (String.isBlank(row.Channel__c) || !VALID_CHANNELS.contains(row.Channel__c)) {
            return 'Unsupported channel: ' + row.Channel__c;
        }
        if (String.isBlank(row.Opt_In_Raw__c)) {
            return 'Opt In Raw is required.';
        }
        String normalised = row.Opt_In_Raw__c.trim().toLowerCase();
        if (!TRUTHY.contains(normalised) && !FALSY.contains(normalised)) {
            return 'Could not interpret consent value: ' + row.Opt_In_Raw__c;
        }
        return null;
    }

    private static Id resolveContact(
        Consent_Staging__c row,
        Map<String, Id> contactIdByEmail,
        Map<String, Id> contactIdByExternalId
    ) {
        // External id wins over email: it is the stable key, whereas email addresses get reused.
        if (String.isNotBlank(row.Contact_External_Id__c)) {
            Id byExternal = contactIdByExternalId.get(row.Contact_External_Id__c);
            if (byExternal != null) {
                return byExternal;
            }
        }
        return String.isBlank(row.Email__c) ? null : contactIdByEmail.get(row.Email__c.toLowerCase());
    }

    private static Boolean isNewer(Consent_Staging__c candidate, Consent_Staging__c incumbent) {
        if (candidate.Captured_At__c == null) {
            return false;
        }
        if (incumbent.Captured_At__c == null) {
            return true;
        }
        return candidate.Captured_At__c > incumbent.Captured_At__c;
    }

    private static String truncate(String value, Integer max) {
        if (String.isBlank(value)) {
            return null;
        }
        return value.length() <= max ? value : value.substring(0, max);
    }
}
