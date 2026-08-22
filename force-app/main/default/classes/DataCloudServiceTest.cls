/**
 * Tests for the Data Cloud layer.
 *
 * The centre of gravity is resolveConsent: it is pure domain logic with real legal consequences,
 * so it is tested directly with hand-built inputs rather than only through the callout path.
 */
@IsTest
private class DataCloudServiceTest {

    /* ------------------------------------------------- Consent resolution (pure) */

    @IsTest
    static void resolveConsent_singleOptOutOverridesEveryOptIn() {
        List<DataCloudService.SourceConsent> sources = new List<DataCloudService.SourceConsent>{
            consent('CRM', 'Email', true),
            consent('POS', 'Email', true),
            consent('Loyalty', 'Email', false)
        };

        List<DataCloudService.ResolvedChannel> resolved = DataCloudService.resolveConsent(sources);

        Assert.areEqual(1, resolved.size(), 'One channel in, one channel out.');
        DataCloudService.ResolvedChannel email = resolved[0];
        Assert.isFalse(email.optIn, 'A single opt-out must win over two opt-ins.');
        Assert.isTrue(email.isConflicted, 'Disagreement between sources must be surfaced, not hidden.');
        Assert.areEqual(3, email.sourcesTotal, 'All three sources should be counted.');
        Assert.isTrue(
            email.reason.contains('Most restrictive wins'),
            'The reason must state the rule that was applied. Got: ' + email.reason
        );
    }

    @IsTest
    static void resolveConsent_unanimousOptInIsNotFlaggedAsConflicted() {
        List<DataCloudService.ResolvedChannel> resolved = DataCloudService.resolveConsent(
            new List<DataCloudService.SourceConsent>{
                consent('CRM', 'SMS', true),
                consent('POS', 'SMS', true)
            }
        );

        Assert.isTrue(resolved[0].optIn, 'Unanimous opt-in resolves to opted in.');
        Assert.isFalse(resolved[0].isConflicted, 'Agreement is not a conflict.');
        Assert.areEqual(2, resolved[0].sourcesAgreeing, 'Both agreeing sources should be counted.');
    }

    @IsTest
    static void resolveConsent_unanimousOptOutIsNotFlaggedAsConflicted() {
        List<DataCloudService.ResolvedChannel> resolved = DataCloudService.resolveConsent(
            new List<DataCloudService.SourceConsent>{
                consent('CRM', 'Push', false),
                consent('POS', 'Push', false)
            }
        );

        Assert.isFalse(resolved[0].optIn, 'Unanimous opt-out resolves to opted out.');
        Assert.isFalse(resolved[0].isConflicted, 'Agreement is not a conflict.');
    }

    @IsTest
    static void resolveConsent_handlesChannelsIndependently() {
        List<DataCloudService.ResolvedChannel> resolved = DataCloudService.resolveConsent(
            new List<DataCloudService.SourceConsent>{
                consent('CRM', 'Email', false),
                consent('CRM', 'SMS', true)
            }
        );

        Map<String, Boolean> optInByChannel = new Map<String, Boolean>();
        for (DataCloudService.ResolvedChannel channel : resolved) {
            optInByChannel.put(channel.channel, channel.optIn);
        }
        Assert.areEqual(2, resolved.size(), 'Two channels should resolve independently.');
        Assert.isFalse(optInByChannel.get('Email'), 'An Email opt-out must not leak into SMS.');
        Assert.isTrue(optInByChannel.get('SMS'), 'An SMS opt-in must not be dragged down by Email.');
    }

    @IsTest
    static void resolveConsent_emptyInputYieldsEmptyOutput() {
        Assert.areEqual(
            0,
            DataCloudService.resolveConsent(new List<DataCloudService.SourceConsent>()).size(),
            'No sources means nothing to resolve.'
        );
    }

    /* ------------------------------------------------------------- Callout path */

    @IsTest
    static void getUnifiedProfile_assemblesGraphConsentAndInsight() {
        Contact contact = TestDataFactory.createContacts(1)[0];
        DataCloudCalloutMock mock = new DataCloudCalloutMock(new List<String>{
            DataCloudCalloutMock.identityGraphResult(contact.Id),
            DataCloudCalloutMock.conflictingConsentResult(contact.Id),
            DataCloudCalloutMock.engagementInsightResult()
        });
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        DataCloudService.UnifiedProfile profile = DataCloudService.getUnifiedProfile(contact.Id);
        Test.stopTest();

        Assert.areEqual('UNI-0001', profile.unifiedId, 'The unified id should come from the identity graph.');
        Assert.areEqual('Dana Reyes', profile.name, 'Name should be assembled from the unified individual.');
        Assert.areEqual(2, profile.sources.size(), 'Two CRM records resolved into this profile.');
        Assert.areEqual(3, mock.queryCallCount, 'Three subject areas means three targeted queries.');

        Map<String, DataCloudService.ResolvedChannel> byChannel =
            new Map<String, DataCloudService.ResolvedChannel>();
        for (DataCloudService.ResolvedChannel channel : profile.resolvedConsent) {
            byChannel.put(channel.channel, channel);
        }
        Assert.isFalse(byChannel.get('Email').optIn, 'The POS opt-out must win for Email.');
        Assert.isTrue(byChannel.get('Email').isConflicted, 'Email is contested across sources.');
        Assert.isTrue(byChannel.get('SMS').optIn, 'SMS is opted in on the only source that has it.');

        Assert.areEqual(82.4, profile.engagement.score, 'The Calculated Insight score should be mapped.');
        Assert.areEqual('Highly engaged', profile.engagement.band, 'A score of 82.4 falls in the top band.');
        Assert.isTrue(profile.queryDurationMs >= 0, 'Query timing should be reported to the UI.');
    }

    /* -------------------------------------------------------- Query trace and gating */

    private static DataCloudService.UnifiedProfile profileWithTrace(Contact contact) {
        Test.setMock(HttpCalloutMock.class, new DataCloudCalloutMock(new List<String>{
            DataCloudCalloutMock.identityGraphResult(contact.Id),
            DataCloudCalloutMock.conflictingConsentResult(contact.Id),
            DataCloudCalloutMock.engagementInsightResult()
        }));
        return DataCloudService.getUnifiedProfile(contact.Id);
    }

    @IsTest
    static void queryTrace_describesEveryQueryItRan() {
        Contact contact = TestDataFactory.createContacts(1)[0];
        DataCloudService.diagnosticsAllowed = true;

        Test.startTest();
        DataCloudService.UnifiedProfile profile = profileWithTrace(contact);
        Test.stopTest();

        Assert.areEqual(3, profile.queries.size(), 'Three queries ran, so three should be reported.');
        Set<String> dmos = new Set<String>();
        for (DataCloudService.QueryTrace t : profile.queries) {
            Assert.isNotNull(t.purpose, 'Every trace entry needs a purpose the UI can label.');
            Assert.isTrue(t.rowCount >= 0, 'Row count is what Data Cloud bills on; it must be reported.');
            Assert.isTrue(t.sql.contains(t.dmo), 'A trace must name the DMO its statement queries.');
            dmos.add(t.dmo);
        }
        Assert.areEqual(3, dmos.size(), 'The three queries should hit three different subject areas.');
    }

    @IsTest
    static void queryTrace_withholdsSqlWithoutTheDiagnosticsPermission() {
        // Query text names every DMO and field the org models. Returning it to a console user
        // who does not hold the permission would leak the Data Cloud schema to the browser.
        Contact contact = TestDataFactory.createContacts(1)[0];
        DataCloudService.diagnosticsAllowed = false;

        Test.startTest();
        DataCloudService.UnifiedProfile profile = profileWithTrace(contact);
        Test.stopTest();

        Assert.areEqual(3, profile.queries.size(), 'Withholding SQL must not remove the trace entries.');
        for (DataCloudService.QueryTrace t : profile.queries) {
            Assert.isNull(t.sql, 'SQL must be withheld without the diagnostics permission.');
            Assert.isNotNull(t.dmo, 'The DMO name and counts stay; only the statement is withheld.');
            Assert.isTrue(t.rowCount >= 0, 'Row counts are not sensitive and should still be reported.');
        }
    }

    @IsTest
    static void getUnifiedProfile_deduplicatesSourcesFannedOutByTheEmailJoin() {
        Contact contact = TestDataFactory.createContacts(1)[0];
        // Same source record repeated, as a LEFT JOIN on multiple emails would produce.
        String duplicated = DataCloudCalloutMock.resultOf(new List<Map<String, Object>>{
            new Map<String, Object>{
                'UnifiedRecordId__c' => 'UNI-0002', 'SourceRecordId__c' => String.valueOf(contact.Id),
                'SourceSystemName__c' => 'CRM', 'MatchConfidence__c' => 1.0,
                'ssot__FirstName__c' => 'Sam', 'ssot__LastName__c' => 'Okafor',
                'ssot__EmailAddress__c' => 'sam@example.invalid', 'ssot__LastModifiedDate__c' => null
            },
            new Map<String, Object>{
                'UnifiedRecordId__c' => 'UNI-0002', 'SourceRecordId__c' => String.valueOf(contact.Id),
                'SourceSystemName__c' => 'CRM', 'MatchConfidence__c' => 1.0,
                'ssot__FirstName__c' => 'Sam', 'ssot__LastName__c' => 'Okafor',
                'ssot__EmailAddress__c' => 'sam.work@example.invalid', 'ssot__LastModifiedDate__c' => null
            }
        });
        Test.setMock(HttpCalloutMock.class, new DataCloudCalloutMock(new List<String>{
            duplicated, DataCloudCalloutMock.emptyResult(), DataCloudCalloutMock.emptyResult()
        }));

        Test.startTest();
        DataCloudService.UnifiedProfile profile = DataCloudService.getUnifiedProfile(contact.Id);
        Test.stopTest();

        Assert.areEqual(1, profile.sources.size(), 'One source record must not appear twice because of the email join.');
    }

    @IsTest
    static void getUnifiedProfile_noMatchExplainsIdentityResolution() {
        Contact contact = TestDataFactory.createContacts(1)[0];
        Test.setMock(HttpCalloutMock.class, new DataCloudCalloutMock(new List<String>{
            DataCloudCalloutMock.emptyResult()
        }));

        Test.startTest();
        try {
            DataCloudService.getUnifiedProfile(contact.Id);
            Assert.fail('A contact with no unified profile should raise a clear error.');
        } catch (AuraHandledException e) {
            Assert.isTrue(
                e.getMessage().contains('Identity Resolution'),
                'The message should point at the likely cause. Got: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void getUnifiedProfile_missingInsightDegradesGracefully() {
        Contact contact = TestDataFactory.createContacts(1)[0];
        Test.setMock(HttpCalloutMock.class, new DataCloudCalloutMock(new List<String>{
            DataCloudCalloutMock.identityGraphResult(contact.Id),
            DataCloudCalloutMock.conflictingConsentResult(contact.Id),
            DataCloudCalloutMock.emptyResult()
        }));

        Test.startTest();
        DataCloudService.UnifiedProfile profile = DataCloudService.getUnifiedProfile(contact.Id);
        Test.stopTest();

        Assert.areEqual('No data', profile.engagement.band, 'A missing Calculated Insight is not an error.');
        Assert.areEqual(0, profile.engagement.score, 'Score should default rather than be null.');
        Assert.isFalse(profile.resolvedConsent.isEmpty(), 'Consent resolution should still have happened.');
    }

    @IsTest
    static void getUnifiedProfile_nullContactIsRejected() {
        try {
            DataCloudService.getUnifiedProfile(null);
            Assert.fail('A null contact should be rejected.');
        } catch (AuraHandledException e) {
            Assert.areEqual('A contact is required.', e.getMessage(), 'Message should be actionable.');
        }
    }

    @IsTest
    static void getUnifiedProfile_contactIdIsBoundAsAQuotedLiteral() {
        Contact contact = TestDataFactory.createContacts(1)[0];
        DataCloudCalloutMock mock = new DataCloudCalloutMock(new List<String>{
            DataCloudCalloutMock.identityGraphResult(contact.Id),
            DataCloudCalloutMock.emptyResult(),
            DataCloudCalloutMock.emptyResult()
        });
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        DataCloudService.getUnifiedProfile(contact.Id);
        Test.stopTest();

        String sql = mock.capturedSql[0];
        Assert.isTrue(
            sql.contains('\'' + contact.Id + '\''),
            'The contact id must reach the tenant as a quoted literal, never bare. Got: ' + sql
        );
    }

    /* ------------------------------------------------------------ Engagement bands */

    @IsTest
    static void bandFor_coversEveryBoundary() {
        Assert.areEqual('Highly engaged', DataCloudService.bandFor(75), '75 is the bottom of the top band.');
        Assert.areEqual('Engaged', DataCloudService.bandFor(74.9), 'Just under 75 drops a band.');
        Assert.areEqual('Engaged', DataCloudService.bandFor(40), '40 is the bottom of the middle band.');
        Assert.areEqual('At risk', DataCloudService.bandFor(39.9), 'Just under 40 drops a band.');
        Assert.areEqual('At risk', DataCloudService.bandFor(0.1), 'Any engagement at all beats dormant.');
        Assert.areEqual('Dormant', DataCloudService.bandFor(0), 'Zero is dormant.');
        Assert.areEqual('No data', DataCloudService.bandFor(null), 'Null is not the same as zero.');
    }

    private static DataCloudService.SourceConsent consent(String system, String channel, Boolean optIn) {
        DataCloudService.SourceConsent entry = new DataCloudService.SourceConsent();
        entry.sourceSystem = system;
        entry.sourceRecordId = system + '-1';
        entry.channel = channel;
        entry.optIn = optIn;
        entry.capturedAt = Datetime.now();
        return entry;
    }

    @IsTest
    static void resolveConsent_readsCorrectlyForASingleSourceProfile() {
        // Most profiles have exactly one source. "All 1 sources agree" reads as a bug on a
        // compliance screen, so the single-source phrasing is asserted explicitly.
        List<DataCloudService.ResolvedChannel> resolved = DataCloudService.resolveConsent(
            new List<DataCloudService.SourceConsent>{ consent('CRM', 'Email', true) }
        );

        Assert.areEqual(
            'The only source on record is opt-in.',
            resolved[0].reason,
            'A single-source profile must not be described in the plural.'
        );
    }

    @IsTest
    static void describeAgreement_handlesSingularAndPlural() {
        Assert.areEqual('The only source on record is opt-out.', DataCloudService.describeAgreement(1, false),
            'One source, singular phrasing.');
        Assert.areEqual('All 2 sources agree on opt-in.', DataCloudService.describeAgreement(2, true),
            'Two sources, plural phrasing.');
    }
}
