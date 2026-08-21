/**
 * Shared fixtures for the Consent Center test suite.
 *
 * Everything returns unsaved records by default so each test decides its own DML shape;
 * the create* helpers insert in one call to keep tests bulk-safe by construction.
 */
@IsTest
public class TestDataFactory {
    public static final List<String> CHANNELS = new List<String>{ 'Email', 'SMS', 'Push', 'Direct Mail' };

    public static List<Contact> buildContacts(Integer count) {
        List<Contact> contacts = new List<Contact>();
        for (Integer i = 0; i < count; i++) {
            contacts.add(new Contact(
                FirstName = 'Test',
                LastName = 'Contact ' + String.valueOf(i).leftPad(4, '0'),
                Email = 'contact' + i + '@example.invalid'
            ));
        }
        return contacts;
    }

    public static List<Contact> createContacts(Integer count) {
        List<Contact> contacts = buildContacts(count);
        insert contacts;
        return contacts;
    }

    public static Consent_Preference__c buildPreference(Id contactId, String channel, Boolean optIn) {
        return new Consent_Preference__c(
            Contact__c = contactId,
            Channel__c = channel,
            Opt_In__c = optIn,
            Consent_Source__c = 'Unit Test',
            Lifecycle_Stage__c = 'Subscriber',
            Last_Changed__c = Datetime.now(),
            Sync_Status__c = 'Pending',
            Sync_Attempts__c = 0,
            External_Key__c = contactId + '-' + channel
        );
    }

    /** One preference per channel for every contact supplied — the standard bulk fixture. */
    public static List<Consent_Preference__c> createPreferencesForAllChannels(List<Contact> contacts, Boolean optIn) {
        List<Consent_Preference__c> prefs = new List<Consent_Preference__c>();
        for (Contact c : contacts) {
            for (String channel : CHANNELS) {
                prefs.add(buildPreference(c.Id, channel, optIn));
            }
        }
        insert prefs;
        return prefs;
    }

    public static List<Sync_Log__c> createSyncLogs(List<Consent_Preference__c> prefs, String status) {
        List<Sync_Log__c> logs = new List<Sync_Log__c>();
        for (Consent_Preference__c pref : prefs) {
            logs.add(new Sync_Log__c(
                Consent_Preference__c = pref.Id,
                Status__c = status,
                Attempt__c = 1,
                Data_Extension_Key__c = 'Consent_Preferences',
                Status_Code__c = status == 'Success' ? 202 : 500,
                Error_Message__c = status == 'Success' ? null : 'Simulated failure',
                Duration_Ms__c = 120,
                Processed_At__c = Datetime.now()
            ));
        }
        insert logs;
        return logs;
    }

    /** Serialises channel changes into the JSON shape ConsentService.savePreferences expects. */
    public static String changesJson(Map<String, Boolean> optInByChannel) {
        List<Map<String, Object>> changes = new List<Map<String, Object>>();
        for (String channel : optInByChannel.keySet()) {
            changes.add(new Map<String, Object>{
                'channel' => channel,
                'optIn' => optInByChannel.get(channel)
            });
        }
        return JSON.serialize(changes);
    }

    /** Pre-seeds a valid token so a test can exercise SfmcClient without an auth round trip. */
    public static void primeSfmcToken() {
        SfmcAuth.Token token = new SfmcAuth.Token();
        token.accessToken = 'test-access-token';
        token.restInstanceUrl = 'https://tenant.rest.marketingcloudapis.com/';
        token.expiresAt = Datetime.now().addMinutes(15);
        SfmcAuth.transactionToken = token;
    }
}
