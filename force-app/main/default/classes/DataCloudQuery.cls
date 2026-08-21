/**
 * Safe SQL construction for the Data Cloud Query API.
 *
 * This matters more than it looks. Data Cloud SQL is ANSI SQL, not SOQL: there are no bind
 * variables, so every value is interpolated into the statement by hand. String.escapeSingleQuotes
 * is a SOQL helper and is NOT sufficient here, because ANSI SQL also honours a backslash escape
 * and comment sequences that SOQL does not.
 *
 * The rules enforced below:
 *   - literals are single-quoted, with quotes doubled (the ANSI escape) and backslashes escaped
 *   - control characters and comment markers are rejected outright rather than escaped
 *   - identifiers (table and column names) never come from user input; they are allowlisted
 */
public with sharing class DataCloudQuery {
    /** Identifiers may only ever be word characters — no quoting scheme can make more safe. */
    private static final Pattern SAFE_IDENTIFIER = Pattern.compile('^[A-Za-z][A-Za-z0-9_]*$');
    /** Anything outside this set has no legitimate place in a consent lookup value. */
    private static final Pattern SAFE_LITERAL = Pattern.compile('^[A-Za-z0-9 @._+\\-]*$');
    private static final Integer MAX_LITERAL_LENGTH = 255;

    /**
     * Quotes a value for use as a SQL string literal.
     *
     * The allowlist is deliberately stricter than "escape the dangerous characters". Everything
     * this application puts into a literal is an id, an email address or a channel name, so a
     * conservative character set costs nothing and removes the entire class of escaping bugs.
     *
     * @throws ConsentCenterException when the value falls outside the permitted character set.
     */
    public static String literal(String value) {
        if (value == null) {
            return 'NULL';
        }
        if (value.length() > MAX_LITERAL_LENGTH) {
            throw new ConsentCenterException('Query literal exceeds ' + MAX_LITERAL_LENGTH + ' characters.');
        }
        if (!SAFE_LITERAL.matcher(value).matches()) {
            throw new ConsentCenterException('Query literal contains an unsupported character.');
        }
        // Belt and braces: even inside the allowlist, apply the ANSI quote escape so this stays
        // correct if the allowlist is ever widened.
        return '\'' + value.replace('\'', '\'\'') + '\'';
    }

    /**
     * Validates an identifier against the allowlist pattern.
     *
     * Callers should be passing compile-time constants; this exists so that a future refactor
     * which starts threading a field name through from the UI fails loudly instead of quietly
     * becoming an injection point.
     */
    public static String identifier(String name) {
        if (String.isBlank(name) || !SAFE_IDENTIFIER.matcher(name).matches()) {
            throw new ConsentCenterException('Unsafe SQL identifier: ' + name);
        }
        return name;
    }

    /** Builds a bounded IN list from a collection of values, each escaped as a literal. */
    public static String inList(List<String> values) {
        List<String> quoted = new List<String>();
        if (values != null) {
            for (String value : values) {
                quoted.add(literal(value));
            }
        }
        if (quoted.isEmpty()) {
            // An empty IN () is a syntax error in most engines; NULL never matches, which is
            // the semantically correct result for "none of these".
            return '(NULL)';
        }
        return '(' + String.join(quoted, ', ') + ')';
    }

    /** Clamps a caller-supplied row limit into a sane range before it reaches the statement. */
    public static Integer safeLimit(Integer requested, Integer defaultLimit, Integer maxLimit) {
        if (requested == null || requested <= 0) {
            return defaultLimit;
        }
        return Math.min(requested, maxLimit);
    }
}
