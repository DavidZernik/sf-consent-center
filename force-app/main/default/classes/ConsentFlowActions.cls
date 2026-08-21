/**
 * Apex actions callable from Flow.
 *
 * Invocable methods are the seam between declarative automation and code. Two rules make that
 * seam behave:
 *
 *   1. The method takes a List and returns a List of the SAME SIZE, in the SAME ORDER. Flow
 *      bulkifies interviews behind the scenes, and returning a differently-sized list is the
 *      single most common way an invocable breaks under load.
 *   2. Failures come back as data on the result, not as thrown exceptions. An exception thrown
 *      here rolls back the entire Flow interview batch, so one bad record would discard the
 *      other 199.
 */
public with sharing class ConsentFlowActions {

    public class ApplyConsentRequest {
        @InvocableVariable(label='Contact ID' description='Contact whose consent is being set.' required=true)
        public Id contactId;

        @InvocableVariable(label='Channel' description='Email, SMS, Push or Direct Mail.' required=true)
        public String channel;

        @InvocableVariable(label='Opt In' description='True to opt in, false to opt out.' required=true)
        public Boolean optIn;

        @InvocableVariable(label='Source' description='Where the change originated, for the audit trail.')
        public String source;
    }

    public class ApplyConsentResult {
        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Preference ID')
        public Id preferenceId;

        @InvocableVariable(label='Message')
        public String message;

        @InvocableVariable(label='Changed' description='False when the requested value was already in place.')
        public Boolean changed;
    }

    /**
     * Sets consent for one contact and channel.
     *
     * All requests are resolved with two queries and two DML statements regardless of how many
     * come in, so a Flow firing on a 10,000-record data load costs the same as one firing on a
     * single record edit.
     */
    @InvocableMethod(
        label='Apply Marketing Consent'
        description='Records a marketing consent decision, writes the audit trail and queues the Marketing Cloud sync.'
        category='Consent Center'
    )
    public static List<ApplyConsentResult> applyConsent(List<ApplyConsentRequest> requests) {
        List<ApplyConsentResult> results = new List<ApplyConsentResult>();
        if (requests == null || requests.isEmpty()) {
            return results;
        }

        // Seed one result per request up front so the return list always matches the input
        // list positionally, even for requests that fail validation below.
        for (Integer i = 0; i < requests.size(); i++) {
            ApplyConsentResult seed = new ApplyConsentResult();
            seed.success = false;
            seed.changed = false;
            results.add(seed);
        }

        Set<Id> contactIds = new Set<Id>();
        for (ApplyConsentRequest request : requests) {
            if (request.contactId != null) {
                contactIds.add(request.contactId);
            }
        }

        Map<String, Consent_Preference__c> existingByKey = new Map<String, Consent_Preference__c>();
        for (Consent_Preference__c pref : [
            SELECT Id, Contact__c, Channel__c, Opt_In__c
            FROM Consent_Preference__c
            WHERE Contact__c IN :contactIds
            WITH SYSTEM_MODE
        ]) {
            existingByKey.put(pref.Contact__c + '|' + pref.Channel__c, pref);
        }

        List<Consent_Preference__c> toUpsert = new List<Consent_Preference__c>();
        List<Consent_History__c> auditTrail = new List<Consent_History__c>();
        Map<Integer, String> keyByIndex = new Map<Integer, String>();
        Datetime now = Datetime.now();
        String actor = UserInfo.getName();

        for (Integer i = 0; i < requests.size(); i++) {
            ApplyConsentRequest request = requests[i];
            ApplyConsentResult result = results[i];

            if (request.contactId == null || String.isBlank(request.channel)) {
                result.message = 'Contact and channel are both required.';
                continue;
            }

            String key = request.contactId + '|' + request.channel;
            Consent_Preference__c existing = existingByKey.get(key);
            Boolean previous = existing != null && existing.Opt_In__c == true;
            Boolean next = request.optIn == true;

            if (existing != null && previous == next) {
                result.success = true;
                result.changed = false;
                result.preferenceId = existing.Id;
                result.message = 'Already ' + (next ? 'opted in' : 'opted out') + '; no change made.';
                continue;
            }

            keyByIndex.put(i, key);
            toUpsert.add(buildPreference(request, existing, next, now));
            auditTrail.add(buildHistory(request, existing, next, actor, now));
        }

        if (toUpsert.isEmpty()) {
            return results;
        }

        // allOrNone=false: one invalid row must not fail the other 199 in the interview batch.
        List<Database.UpsertResult> upsertResults = Database.upsert(toUpsert, false, AccessLevel.SYSTEM_MODE);
        applyOutcomes(results, keyByIndex, toUpsert, upsertResults);

        Database.insert(auditTrail, false, AccessLevel.SYSTEM_MODE);
        return results;
    }

    /** Builds the preference record for one request — insert shape or update shape. */
    private static Consent_Preference__c buildPreference(
        ApplyConsentRequest request,
        Consent_Preference__c existing,
        Boolean next,
        Datetime now
    ) {
        Consent_Preference__c record = existing == null
            ? new Consent_Preference__c(Contact__c = request.contactId, Channel__c = request.channel)
            : new Consent_Preference__c(Id = existing.Id);
        record.Opt_In__c = next;
        record.Consent_Source__c = sourceOf(request);
        record.Last_Changed__c = now;
        record.Sync_Status__c = 'Pending';
        record.Sync_Attempts__c = 0;
        return record;
    }

    /** Builds the audit row describing the transition this request causes. */
    private static Consent_History__c buildHistory(
        ApplyConsentRequest request,
        Consent_Preference__c existing,
        Boolean next,
        String actor,
        Datetime now
    ) {
        Boolean previous = existing != null && existing.Opt_In__c == true;
        return new Consent_History__c(
            Contact__c = request.contactId,
            Channel__c = request.channel,
            Previous_Value__c = existing == null ? 'None' : (previous ? 'Opted In' : 'Opted Out'),
            New_Value__c = next ? 'Opted In' : 'Opted Out',
            Changed_By_Name__c = actor,
            Change_Source__c = sourceOf(request),
            Changed_At__c = now
        );
    }

    /** Flow may leave the source blank; the audit trail must still say where it came from. */
    private static String sourceOf(ApplyConsentRequest request) {
        return String.isBlank(request.source) ? 'Flow' : request.source;
    }

    /**
     * Copies the DML outcome for each written record back onto the result at its ORIGINAL index.
     *
     * The index mapping is the whole point. Flow pairs the Nth result with the Nth request, so a
     * result written to the wrong slot silently attributes one record's failure to another —
     * a bug that looks like data corruption rather than a bad write.
     */
    private static void applyOutcomes(
        List<ApplyConsentResult> results,
        Map<Integer, String> keyByIndex,
        List<Consent_Preference__c> written,
        List<Database.UpsertResult> upsertResults
    ) {
        Map<String, Database.UpsertResult> outcomeByKey = new Map<String, Database.UpsertResult>();
        Map<String, Id> idByKey = new Map<String, Id>();
        for (Integer i = 0; i < written.size(); i++) {
            String key = written[i].Contact__c + '|' + written[i].Channel__c;
            outcomeByKey.put(key, upsertResults[i]);
            idByKey.put(key, written[i].Id);
        }

        for (Integer index : keyByIndex.keySet()) {
            String key = keyByIndex.get(index);
            Database.UpsertResult outcome = outcomeByKey.get(key);
            ApplyConsentResult result = results[index];
            if (outcome != null && outcome.isSuccess()) {
                result.success = true;
                result.changed = true;
                result.preferenceId = idByKey.get(key);
                result.message = 'Consent recorded.';
            } else {
                result.message = outcome == null
                    ? 'Record was not processed.'
                    : outcome.getErrors()[0].getMessage();
            }
        }
    }
}
