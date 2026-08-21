/**
 * Tests for Data Cloud SQL construction.
 *
 * These are the security tests of the repository. Data Cloud SQL has no bind variables, so if
 * literal() or identifier() is wrong, the application has an injection vulnerability rather than
 * a formatting bug.
 */
// Assertions in this class run through the assertRejected helper, which PMD cannot follow
// across the call boundary. Every test does assert; see the helper at the foot of the class.
@SuppressWarnings('PMD.ApexUnitTestClassShouldHaveAsserts')
@IsTest
private class DataCloudQueryTest {

    @IsTest
    static void literal_quotesOrdinaryValues() {
        Assert.areEqual('\'Email\'', DataCloudQuery.literal('Email'), 'A plain value should be single-quoted.');
        Assert.areEqual(
            '\'dana.reyes+news@example.com\'',
            DataCloudQuery.literal('dana.reyes+news@example.com'),
            'Email punctuation is inside the allowlist and must survive.'
        );
        Assert.areEqual('NULL', DataCloudQuery.literal(null), 'Null becomes the SQL NULL keyword, not an empty string.');
    }

    @IsTest
    static void literal_rejectsQuoteBreakout() {
        assertRejected('\' OR 1=1 --', 'A classic quote-breakout payload must be rejected.');
    }

    @IsTest
    static void literal_rejectsStatementTermination() {
        assertRejected('x\'; DROP TABLE Consent__dlm; --', 'A stacked-statement payload must be rejected.');
    }

    @IsTest
    static void literal_rejectsCommentMarkers() {
        assertRejected('value--comment', 'An inline comment marker must be rejected.');
        assertRejected('value/*block*/', 'A block comment marker must be rejected.');
    }

    @IsTest
    static void literal_rejectsBackslashEscape() {
        // An engine honouring backslash escapes could otherwise be used to neutralise the
        // quote doubling that protects the literal.
        assertRejected('value\\', 'A trailing backslash must be rejected.');
    }

    @IsTest
    static void literal_rejectsControlCharacters() {
        assertRejected('line1\nline2', 'A newline must be rejected.');
        assertRejected('tab\there', 'A tab must be rejected.');
    }

    @IsTest
    static void literal_rejectsOversizedValues() {
        assertRejected('a'.repeat(256), 'A value beyond the length ceiling must be rejected.');
    }

    @IsTest
    static void identifier_acceptsRealDmoNames() {
        Assert.areEqual(
            'UnifiedIndividual__dlm',
            DataCloudQuery.identifier('UnifiedIndividual__dlm'),
            'A standard DMO name should pass the allowlist.'
        );
        Assert.areEqual(
            'Engagement_Score__cio',
            DataCloudQuery.identifier('Engagement_Score__cio'),
            'A Calculated Insight name should pass the allowlist.'
        );
    }

    @IsTest
    static void identifier_rejectsAnythingElse() {
        for (String candidate : new List<String>{
            'table; DROP TABLE x',
            'table name',
            '1_starts_with_digit',
            'quoted"name',
            '',
            null
        }) {
            try {
                DataCloudQuery.identifier(candidate);
                Assert.fail('Identifier should have been rejected: ' + candidate);
            } catch (ConsentCenterException e) {
                Assert.isTrue(
                    e.getMessage().contains('Unsafe SQL identifier'),
                    'The error should name the problem. Got: ' + e.getMessage()
                );
            }
        }
    }

    @IsTest
    static void inList_quotesEveryElement() {
        String result = DataCloudQuery.inList(new List<String>{ 'a1', 'b2' });
        Assert.areEqual('(\'a1\', \'b2\')', result, 'Every element must be individually quoted.');
    }

    @IsTest
    static void inList_emptyProducesAMatchNothingPredicate() {
        // An empty IN () is a syntax error; NULL never matches, which is the correct semantics.
        Assert.areEqual('(NULL)', DataCloudQuery.inList(new List<String>()), 'An empty list must not emit IN ().');
        Assert.areEqual('(NULL)', DataCloudQuery.inList(null), 'A null list must not throw.');
    }

    @IsTest
    static void inList_rejectsAnInjectedElement() {
        try {
            DataCloudQuery.inList(new List<String>{ 'safe', '\' OR 1=1 --' });
            Assert.fail('One bad element must reject the whole list.');
        } catch (ConsentCenterException e) {
            Assert.isTrue(e.getMessage().contains('unsupported character'), 'Got: ' + e.getMessage());
        }
    }

    @IsTest
    static void safeLimit_clampsToTheCeiling() {
        Assert.areEqual(50, DataCloudQuery.safeLimit(null, 50, 200), 'Null falls back to the default.');
        Assert.areEqual(50, DataCloudQuery.safeLimit(0, 50, 200), 'Zero falls back to the default.');
        Assert.areEqual(50, DataCloudQuery.safeLimit(-10, 50, 200), 'A negative falls back to the default.');
        Assert.areEqual(75, DataCloudQuery.safeLimit(75, 50, 200), 'A sane request is honoured.');
        Assert.areEqual(200, DataCloudQuery.safeLimit(999999, 50, 200), 'An absurd request is clamped to the ceiling.');
    }

    private static void assertRejected(String value, String because) {
        try {
            DataCloudQuery.literal(value);
            Assert.fail(because + ' Value was accepted: ' + value);
        } catch (ConsentCenterException e) {
            Assert.isTrue(
                e.getMessage().contains('unsupported character') || e.getMessage().contains('exceeds'),
                'Rejection reason should be explicit. Got: ' + e.getMessage()
            );
        }
    }
}
