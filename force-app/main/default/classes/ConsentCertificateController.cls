/**
 * Controller for the proof-of-consent PDF.
 *
 * Standard controller conventions apply: all data is loaded once in the constructor, and the
 * getters are pure. A getter that queries is a getter that runs an unknown number of times
 * during the render phase, which is how Visualforce pages quietly blow the SOQL limit.
 */
public with sharing class ConsentCertificateController {
    private static final ConsentSelector SELECTOR = new ConsentSelector();
    private static final List<String> CHANNELS = new List<String>{ 'Email', 'SMS', 'Push', 'Direct Mail' };

    public Id contactId { get; private set; }
    public String contactName { get; private set; }
    public String contactEmail { get; private set; }
    public String lifecycleStage { get; private set; }
    public Datetime generatedAt { get; private set; }
    public String referenceNumber { get; private set; }
    public List<ChannelRow> channelRows { get; private set; }
    public List<HistoryRow> historyRows { get; private set; }

    public Boolean getHasHistory() {
        return !historyRows.isEmpty();
    }

    public class ChannelRow {
        public String channel { get; private set; }
        public Boolean optIn { get; private set; }
        public String source { get; private set; }
        public String lastChangedLabel { get; private set; }

        public ChannelRow(String channel, Boolean optIn, String source, Datetime lastChanged) {
            this.channel = channel;
            this.optIn = optIn;
            this.source = String.isBlank(source) ? 'Not recorded' : source;
            this.lastChangedLabel = lastChanged == null ? 'Never' : lastChanged.format('d MMM yyyy, HH:mm');
        }
    }

    public class HistoryRow {
        public String channel { get; private set; }
        public String transition { get; private set; }
        public String actor { get; private set; }
        public String changedAtLabel { get; private set; }

        public HistoryRow(Consent_History__c entry) {
            this.channel = entry.Channel__c;
            this.transition = entry.Previous_Value__c + ' to ' + entry.New_Value__c;
            this.actor = entry.Changed_By_Name__c + ' (' + entry.Change_Source__c + ')';
            this.changedAtLabel = entry.Changed_At__c == null
                ? ''
                : entry.Changed_At__c.format('d MMM yyyy, HH:mm');
        }
    }

    public ConsentCertificateController() {
        this.generatedAt = Datetime.now();
        this.channelRows = new List<ChannelRow>();
        this.historyRows = new List<HistoryRow>();

        String idParam = ApexPages.currentPage() == null
            ? null
            : ApexPages.currentPage().getParameters().get('id');

        if (String.isBlank(idParam)) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'No contact was supplied.'));
            return;
        }

        try {
            this.contactId = Id.valueOf(idParam);
        } catch (System.StringException e) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'That is not a valid record id.'));
            return;
        }

        // Reference number is deterministic for the contact and the day, so regenerating the
        // certificate for an audit produces the same reference rather than a new one each time.
        this.referenceNumber = 'CC-' + String.valueOf(contactId).substring(0, 15).toUpperCase()
            + '-' + generatedAt.formatGmt('yyyyMMdd');

        load();
    }

    private void load() {
        Set<Id> ids = new Set<Id>{ contactId };
        Map<String, Consent_Preference__c> byChannel = new Map<String, Consent_Preference__c>();

        for (Consent_Preference__c pref : SELECTOR.selectByContactIds(ids)) {
            byChannel.put(pref.Channel__c, pref);
            if (contactName == null && pref.Contact__r != null) {
                contactName = pref.Contact__r.Name;
                contactEmail = pref.Contact__r.Email;
            }
            if (lifecycleStage == null) {
                lifecycleStage = pref.Lifecycle_Stage__c;
            }
        }

        // Every channel appears, including ones with no record, so the certificate is a
        // complete statement rather than a partial one.
        for (String channel : CHANNELS) {
            Consent_Preference__c pref = byChannel.get(channel);
            channelRows.add(new ChannelRow(
                channel,
                pref != null && pref.Opt_In__c == true,
                pref == null ? null : pref.Consent_Source__c,
                pref == null ? null : pref.Last_Changed__c
            ));
        }

        for (Consent_History__c entry : SELECTOR.selectHistoryByContactIds(ids, 100)) {
            historyRows.add(new HistoryRow(entry));
        }

        if (contactName == null) {
            List<Contact> contacts = [SELECT Name, Email FROM Contact WHERE Id = :contactId WITH USER_MODE LIMIT 1];
            if (!contacts.isEmpty()) {
                contactName = contacts[0].Name;
                contactEmail = contacts[0].Email;
            }
        }
        if (String.isBlank(lifecycleStage)) {
            lifecycleStage = 'Not set';
        }
    }
}
