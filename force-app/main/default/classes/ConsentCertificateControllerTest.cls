/**
 * Tests for the Visualforce PDF controller.
 *
 * The certificate is a compliance artefact, so the assertions are about completeness: every
 * channel appears whether or not a record exists, and a missing contact does not produce a
 * half-rendered document.
 */
@IsTest
private class ConsentCertificateControllerTest {

    @IsTest
    static void controller_listsEveryChannelIncludingOnesWithNoRecord() {
        Contact contact = TestDataFactory.createContacts(1)[0];
        Consent_Preference__c pref = TestDataFactory.buildPreference(contact.Id, 'Email', true);

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        insert pref;
        PageReference page = Page.ConsentCertificate;
        page.getParameters().put('id', contact.Id);
        Test.setCurrentPage(page);
        ConsentCertificateController controller = new ConsentCertificateController();
        Test.stopTest();

        Assert.areEqual(
            4,
            controller.channelRows.size(),
            'A certificate must state every channel, including ones with no record, or it is not a complete statement.'
        );

        Map<String, Boolean> optInByChannel = new Map<String, Boolean>();
        for (ConsentCertificateController.ChannelRow row : controller.channelRows) {
            optInByChannel.put(row.channel, row.optIn);
        }
        Assert.isTrue(optInByChannel.get('Email'), 'Email has a record and is opted in.');
        Assert.isFalse(optInByChannel.get('Push'), 'Push has no record and must default to opted out.');
    }

    @IsTest
    static void controller_populatesContactDetails() {
        Contact contact = TestDataFactory.createContacts(1)[0];

        Test.setMock(HttpCalloutMock.class, SfmcCalloutMock.success());
        Test.startTest();
        insert TestDataFactory.buildPreference(contact.Id, 'Email', true);
        PageReference page = Page.ConsentCertificate;
        page.getParameters().put('id', contact.Id);
        Test.setCurrentPage(page);
        ConsentCertificateController controller = new ConsentCertificateController();
        Test.stopTest();

        Assert.isNotNull(controller.contactName, 'The certificate needs a name on it.');
        Assert.isNotNull(controller.contactEmail, 'The certificate needs an email on it.');
        Assert.isNotNull(controller.generatedAt, 'The generation timestamp is part of the artefact.');
        Assert.isTrue(
            controller.referenceNumber.startsWith('CC-'),
            'The reference number should be recognisable. Got: ' + controller.referenceNumber
        );
    }

    @IsTest
    static void controller_referenceNumberIsStableForTheSameContactAndDay() {
        Contact contact = TestDataFactory.createContacts(1)[0];
        PageReference page = Page.ConsentCertificate;
        page.getParameters().put('id', contact.Id);
        Test.setCurrentPage(page);

        Test.startTest();
        String first = new ConsentCertificateController().referenceNumber;
        String second = new ConsentCertificateController().referenceNumber;
        Test.stopTest();

        Assert.areEqual(
            first,
            second,
            'Regenerating a certificate for an audit must produce the same reference, not a new one.'
        );
    }

    @IsTest
    static void controller_rendersHistoryWhenPresent() {
        Contact contact = TestDataFactory.createContacts(1)[0];
        insert new Consent_History__c(
            Contact__c = contact.Id, Channel__c = 'Email',
            Previous_Value__c = 'Opted In', New_Value__c = 'Opted Out',
            Changed_By_Name__c = 'Test User', Change_Source__c = 'Preference Centre',
            Changed_At__c = Datetime.now()
        );

        PageReference page = Page.ConsentCertificate;
        page.getParameters().put('id', contact.Id);
        Test.setCurrentPage(page);

        Test.startTest();
        ConsentCertificateController controller = new ConsentCertificateController();
        Test.stopTest();

        Assert.isTrue(controller.getHasHistory(), 'History exists and should be flagged for the page.');
        Assert.areEqual(
            'Opted In to Opted Out',
            controller.historyRows[0].transition,
            'The transition should read as a sentence on the printed page.'
        );
    }

    @IsTest
    static void controller_missingParameterAddsAPageMessage() {
        Test.setCurrentPage(Page.ConsentCertificate);

        Test.startTest();
        ConsentCertificateController controller = new ConsentCertificateController();
        Test.stopTest();

        Assert.isTrue(ApexPages.hasMessages(ApexPages.Severity.ERROR), 'A missing id should surface as a page message.');
        Assert.areEqual(0, controller.channelRows.size(), 'Nothing should be rendered without a contact.');
    }

    @IsTest
    static void controller_invalidIdIsHandled() {
        PageReference page = Page.ConsentCertificate;
        page.getParameters().put('id', 'not-a-valid-id');
        Test.setCurrentPage(page);

        Test.startTest();
        ConsentCertificateController controller = new ConsentCertificateController();
        Test.stopTest();

        Assert.isTrue(ApexPages.hasMessages(ApexPages.Severity.ERROR), 'A malformed id should not throw an unhandled exception.');
        Assert.isNull(controller.contactId, 'No contact should have been resolved.');
    }
}
