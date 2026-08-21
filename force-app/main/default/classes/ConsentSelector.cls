/**
 * SOQL boundary for the Consent Center.
 *
 * Every query runs in USER_MODE so field- and object-level security is enforced by the
 * platform rather than re-implemented here. Keeping SOQL in one class means bulkification
 * and security posture are reviewable in a single place, and the service layer stays
 * testable without touching the database.
 */
public with sharing class ConsentSelector {
    /** Defensive ceiling so a wide-open search can never approach the 50k row limit. */
    public static final Integer DEFAULT_MAX_ROWS = 200;

    /**
     * Consent preference records for a set of contacts.
     * @param contactIds Contacts to load. An empty set short-circuits without a query.
     */
    public List<Consent_Preference__c> selectByContactIds(Set<Id> contactIds) {
        if (contactIds == null || contactIds.isEmpty()) {
            return new List<Consent_Preference__c>();
        }
        return [
            SELECT Id, Contact__c, Contact__r.Name, Contact__r.Email, Channel__c,
                   Opt_In__c, Consent_Source__c, Lifecycle_Stage__c, Last_Changed__c,
                   Sync_Status__c, Sync_Attempts__c, Last_Sync_Error__c
            FROM Consent_Preference__c
            WHERE Contact__c IN :contactIds
            WITH USER_MODE
            ORDER BY Contact__r.Name, Channel__c
            LIMIT :DEFAULT_MAX_ROWS
        ];
    }

    /**
     * Search preferences by contact name/email, optionally narrowed to one channel.
     *
     * The search term is bound (never concatenated) and escaped with String.escapeSingleQuotes
     * before the LIKE wildcards are added, so a term containing % or _ cannot widen the query.
     */
    public List<Consent_Preference__c> searchSummaries(String searchTerm, String channel, Integer maxRows) {
        Integer rowLimit = (maxRows == null || maxRows <= 0) ? DEFAULT_MAX_ROWS : Math.min(maxRows, DEFAULT_MAX_ROWS);
        Boolean hasSearch = String.isNotBlank(searchTerm);
        Boolean hasChannel = String.isNotBlank(channel) && channel != 'All';
        String pattern = hasSearch ? '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%' : '%';

        if (hasChannel) {
            return [
                SELECT Id, Contact__c, Contact__r.Name, Contact__r.Email, Channel__c,
                       Opt_In__c, Consent_Source__c, Lifecycle_Stage__c, Last_Changed__c, Sync_Status__c
                FROM Consent_Preference__c
                WHERE Channel__c = :channel
                  AND (Contact__r.Name LIKE :pattern OR Contact__r.Email LIKE :pattern)
                WITH USER_MODE
                ORDER BY Last_Changed__c DESC NULLS LAST
                LIMIT :rowLimit
            ];
        }
        return [
            SELECT Id, Contact__c, Contact__r.Name, Contact__r.Email, Channel__c,
                   Opt_In__c, Consent_Source__c, Lifecycle_Stage__c, Last_Changed__c, Sync_Status__c
            FROM Consent_Preference__c
            WHERE Contact__r.Name LIKE :pattern OR Contact__r.Email LIKE :pattern
            WITH USER_MODE
            ORDER BY Last_Changed__c DESC NULLS LAST
            LIMIT :rowLimit
        ];
    }

    /** Audit trail entries for a set of contacts, newest first. */
    public List<Consent_History__c> selectHistoryByContactIds(Set<Id> contactIds, Integer maxRows) {
        if (contactIds == null || contactIds.isEmpty()) {
            return new List<Consent_History__c>();
        }
        Integer rowLimit = (maxRows == null || maxRows <= 0) ? DEFAULT_MAX_ROWS : Math.min(maxRows, DEFAULT_MAX_ROWS);
        return [
            SELECT Id, Contact__c, Channel__c, Previous_Value__c, New_Value__c,
                   Changed_By_Name__c, Change_Source__c, Changed_At__c
            FROM Consent_History__c
            WHERE Contact__c IN :contactIds
            WITH USER_MODE
            ORDER BY Changed_At__c DESC
            LIMIT :rowLimit
        ];
    }

    /** Marketing Cloud sync log entries, optionally filtered by status. */
    public List<Sync_Log__c> selectSyncLogs(String status, Integer maxRows) {
        Integer rowLimit = (maxRows == null || maxRows <= 0) ? DEFAULT_MAX_ROWS : Math.min(maxRows, DEFAULT_MAX_ROWS);
        if (String.isNotBlank(status) && status != 'All') {
            return [
                SELECT Id, Consent_Preference__c, Consent_Preference__r.Contact__r.Name,
                       Consent_Preference__r.Channel__c, Status__c, Attempt__c, Data_Extension_Key__c,
                       Status_Code__c, Error_Message__c, Duration_Ms__c, Processed_At__c
                FROM Sync_Log__c
                WHERE Status__c = :status
                WITH USER_MODE
                ORDER BY Processed_At__c DESC
                LIMIT :rowLimit
            ];
        }
        return [
            SELECT Id, Consent_Preference__c, Consent_Preference__r.Contact__r.Name,
                   Consent_Preference__r.Channel__c, Status__c, Attempt__c, Data_Extension_Key__c,
                   Status_Code__c, Error_Message__c, Duration_Ms__c, Processed_At__c
            FROM Sync_Log__c
            WITH USER_MODE
            ORDER BY Processed_At__c DESC
            LIMIT :rowLimit
        ];
    }

    /**
     * Preferences still awaiting a successful push to Marketing Cloud.
     *
     * Runs in SYSTEM_MODE deliberately: this feeds the async backfill job, which must see
     * every pending row regardless of which user happened to trigger it.
     */
    public List<Consent_Preference__c> selectPendingSync(Integer maxRows) {
        Integer rowLimit = (maxRows == null || maxRows <= 0) ? DEFAULT_MAX_ROWS : maxRows;
        return [
            SELECT Id, Contact__c, Contact__r.Email, Channel__c, Opt_In__c,
                   Consent_Source__c, Sync_Status__c, Sync_Attempts__c, Last_Changed__c
            FROM Consent_Preference__c
            WHERE Sync_Status__c IN ('Pending', 'Failed')
            WITH SYSTEM_MODE
            ORDER BY Last_Changed__c ASC NULLS FIRST
            LIMIT :rowLimit
        ];
    }

    /**
     * Cross-object search using SOSL.
     *
     * SOQL cannot answer "find this person anywhere" in one round trip. It would take a query
     * per object plus LIKE scans that ignore the search index. SOSL hits the index once and
     * spans Contact, Lead and the consent audit trail together, which is both faster and the
     * only thing that finds a match on a field the caller did not think to name.
     *
     * The term is escaped for SOSL specifically: the reserved characters differ from SOQL's,
     * and an unescaped ? or * silently turns an exact search into a wildcard scan.
     */
    public SearchResults searchEverywhere(String searchTerm, Integer maxRows) {
        SearchResults results = new SearchResults();
        if (String.isBlank(searchTerm) || searchTerm.trim().length() < 2) {
            // SOSL requires at least two characters; returning empty beats a runtime exception.
            return results;
        }

        Integer rowLimit = (maxRows == null || maxRows <= 0) ? 20 : Math.min(maxRows, 50);
        String escaped = escapeSosl(searchTerm.trim());

        List<List<SObject>> found = [
            FIND :escaped
            IN ALL FIELDS
            RETURNING
                Contact(Id, Name, Email, Title ORDER BY Name LIMIT :rowLimit),
                Lead(Id, Name, Email, Company ORDER BY Name LIMIT :rowLimit),
                Consent_Preference__c(Id, Contact__c, Contact__r.Name, Channel__c, Opt_In__c, Consent_Source__c
                    ORDER BY Last_Changed__c DESC LIMIT :rowLimit)
            WITH USER_MODE
            LIMIT 200
        ];

        results.contacts = (List<Contact>) found[0];
        results.leads = (List<Lead>) found[1];
        results.preferences = (List<Consent_Preference__c>) found[2];
        return results;
    }

    /** Grouped SOSL output, so callers do not depend on the positional result array. */
    public class SearchResults {
        public List<Contact> contacts = new List<Contact>();
        public List<Lead> leads = new List<Lead>();
        public List<Consent_Preference__c> preferences = new List<Consent_Preference__c>();

        public Integer totalSize() {
            return contacts.size() + leads.size() + preferences.size();
        }
    }

    /**
     * Escapes the SOSL reserved character set.
     *
     * This is not the same list as SOQL's. String.escapeSingleQuotes handles the quote and
     * nothing else, so relying on it here would leave ? * and the boolean operators live.
     */
    @TestVisible
    private static String escapeSosl(String term) {
        String escaped = term;
        for (String reserved : new List<String>{
            '\\', '?', '&', '|', '!', '{', '}', '[', ']', '(', ')', '^', '~', '*', ':', '"', '+', '-'
        }) {
            escaped = escaped.replace(reserved, '\\' + reserved);
        }
        return escaped.replace('\'', '\\\'');
    }
}
