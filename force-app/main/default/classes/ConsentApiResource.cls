/**
 * Inbound REST endpoint for real-time consent capture.
 *
 * This is the real-time half of the integration pattern; ConsentStagingBatch is the batch half.
 * An external preference centre, a mobile app or an iPaaS flow POSTs here and gets a synchronous
 * answer. Anything high-volume should land in the staging object instead — a REST call per row
 * is the wrong shape for a million-row reconciliation.
 *
 *   POST /services/apexrest/consent/v1/
 *   { "records": [ { "email": "...", "channel": "Email", "optIn": false, "source": "..." } ] }
 *
 * Responses are per-record rather than all-or-nothing, so a caller sending 50 rows learns
 * exactly which ones failed instead of getting one opaque 400.
 */
@RestResource(urlMapping='/consent/v1/*')
// Apex REST entry points must be global; this is a platform requirement, not a design choice.
@SuppressWarnings('PMD.AvoidGlobalModifier')
global with sharing class ConsentApiResource {
    /** Bounded so a caller cannot push the transaction past the DML row limit. */
    private static final Integer MAX_RECORDS_PER_REQUEST = 200;

    global class ConsentRecordInput {
        global String email;
        global String contactId;
        global String channel;
        global Boolean optIn;
        global String source;
        /** Caller's own identifier, echoed back so they can correlate the outcome. */
        global String externalReference;
    }

    global class ConsentRecordOutcome {
        global String externalReference;
        global String status;
        global String contactId;
        global String message;
    }

    global class ApiResponse {
        global Boolean success;
        global Integer accepted;
        global Integer rejected;
        global List<ConsentRecordOutcome> results;
        global String message;
    }

    /**
     * Accepts a batch of consent decisions.
     *
     * Contacts are resolved by email in a single query rather than one lookup per row, which is
     * what keeps a 200-record payload inside one SOQL query instead of 200.
     */
    @HttpPost
    global static ApiResponse upsertConsent() {
        RestResponse response = RestContext.response;
        ApiResponse result = new ApiResponse();
        result.results = new List<ConsentRecordOutcome>();
        result.accepted = 0;
        result.rejected = 0;

        try {
            List<ConsentRecordInput> records = parseRequest();

            if (records.isEmpty()) {
                response.statusCode = 400;
                result.success = false;
                result.message = 'The request contained no records.';
                return result;
            }
            if (records.size() > MAX_RECORDS_PER_REQUEST) {
                response.statusCode = 413;
                result.success = false;
                result.message = 'A request may contain at most ' + MAX_RECORDS_PER_REQUEST + ' records.';
                return result;
            }

            // One query resolves every email in the payload.
            Set<String> emails = new Set<String>();
            for (ConsentRecordInput record : records) {
                if (String.isNotBlank(record.email)) {
                    emails.add(record.email.toLowerCase());
                }
            }
            Map<String, Id> contactIdByEmail = new Map<String, Id>();
            if (!emails.isEmpty()) {
                for (Contact contact : [
                    SELECT Id, Email FROM Contact
                    WHERE Email IN :emails
                    WITH USER_MODE
                    LIMIT 1000
                ]) {
                    contactIdByEmail.put(contact.Email.toLowerCase(), contact.Id);
                }
            }

            // Reuse the Flow invocable rather than duplicating the write path: one place decides
            // what "recording consent" means, and both entry points inherit any fix to it.
            List<ConsentFlowActions.ApplyConsentRequest> applyRequests =
                new List<ConsentFlowActions.ApplyConsentRequest>();
            List<ConsentRecordOutcome> pending = new List<ConsentRecordOutcome>();

            for (ConsentRecordInput record : records) {
                ConsentRecordOutcome outcome = new ConsentRecordOutcome();
                outcome.externalReference = record.externalReference;

                Id resolvedId = resolveContactId(record, contactIdByEmail);
                String validationError = validate(record, resolvedId);
                if (validationError != null) {
                    outcome.status = 'Rejected';
                    outcome.message = validationError;
                    result.results.add(outcome);
                    result.rejected++;
                    continue;
                }

                outcome.contactId = resolvedId;
                pending.add(outcome);

                ConsentFlowActions.ApplyConsentRequest applyRequest = new ConsentFlowActions.ApplyConsentRequest();
                applyRequest.contactId = resolvedId;
                applyRequest.channel = record.channel;
                applyRequest.optIn = record.optIn;
                applyRequest.source = String.isBlank(record.source) ? 'REST API' : record.source;
                applyRequests.add(applyRequest);
            }

            if (!applyRequests.isEmpty()) {
                List<ConsentFlowActions.ApplyConsentResult> applied =
                    ConsentFlowActions.applyConsent(applyRequests);

                for (Integer i = 0; i < pending.size(); i++) {
                    ConsentRecordOutcome outcome = pending[i];
                    ConsentFlowActions.ApplyConsentResult applyResult = applied[i];
                    if (applyResult.success) {
                        outcome.status = applyResult.changed ? 'Applied' : 'Unchanged';
                        result.accepted++;
                    } else {
                        outcome.status = 'Rejected';
                        result.rejected++;
                    }
                    outcome.message = applyResult.message;
                    result.results.add(outcome);
                }
            }

            result.success = result.rejected == 0;
            // 200 when everything landed, 207 Multi-Status when the outcome was mixed.
            response.statusCode = result.success ? 200 : 207;
            result.message = result.accepted + ' accepted, ' + result.rejected + ' rejected.';
            return result;
        } catch (JSONException e) {
            response.statusCode = 400;
            result.success = false;
            result.message = 'Malformed JSON: ' + e.getMessage();
            return result;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString());
            response.statusCode = 500;
            result.success = false;
            // Never echo an internal message to an unauthenticated-ish caller.
            result.message = 'The request could not be processed.';
            return result;
        }
    }

    /** Current consent for one contact, for a caller that needs to render a preference centre. */
    @HttpGet
    global static ApiResponse getConsent() {
        RestResponse response = RestContext.response;
        ApiResponse result = new ApiResponse();
        result.results = new List<ConsentRecordOutcome>();

        String contactId = RestContext.request.params.get('contactId');
        if (String.isBlank(contactId)) {
            response.statusCode = 400;
            result.success = false;
            result.message = 'A contactId parameter is required.';
            return result;
        }

        try {
            for (Consent_Preference__c pref : new ConsentSelector().selectByContactIds(
                new Set<Id>{ Id.valueOf(contactId) }
            )) {
                ConsentRecordOutcome outcome = new ConsentRecordOutcome();
                outcome.contactId = pref.Contact__c;
                outcome.status = pref.Opt_In__c == true ? 'OptIn' : 'OptOut';
                outcome.message = pref.Channel__c;
                result.results.add(outcome);
            }
            result.success = true;
            result.accepted = result.results.size();
            result.rejected = 0;
            response.statusCode = 200;
            return result;
        } catch (System.StringException e) {
            response.statusCode = 400;
            result.success = false;
            result.message = 'That is not a valid record id.';
            return result;
        }
    }

    private static List<ConsentRecordInput> parseRequest() {
        String body = RestContext.request.requestBody == null
            ? null
            : RestContext.request.requestBody.toString();
        if (String.isBlank(body)) {
            return new List<ConsentRecordInput>();
        }
        Map<String, Object> envelope = (Map<String, Object>) JSON.deserializeUntyped(body);
        Object records = envelope.get('records');
        if (records == null) {
            return new List<ConsentRecordInput>();
        }
        return (List<ConsentRecordInput>) JSON.deserialize(
            JSON.serialize(records),
            List<ConsentRecordInput>.class
        );
    }

    private static Id resolveContactId(ConsentRecordInput record, Map<String, Id> contactIdByEmail) {
        if (String.isNotBlank(record.contactId)) {
            try {
                return Id.valueOf(record.contactId);
            } catch (System.StringException e) {
                return null;
            }
        }
        return String.isBlank(record.email) ? null : contactIdByEmail.get(record.email.toLowerCase());
    }

    private static String validate(ConsentRecordInput record, Id resolvedId) {
        if (resolvedId == null) {
            return String.isBlank(record.email) && String.isBlank(record.contactId)
                ? 'Either email or contactId is required.'
                : 'No contact matched the supplied identifier.';
        }
        if (String.isBlank(record.channel)) {
            return 'A channel is required.';
        }
        if (record.optIn == null) {
            return 'optIn must be true or false.';
        }
        return null;
    }
}
