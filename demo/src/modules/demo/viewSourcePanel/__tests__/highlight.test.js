import { highlight, languageFor } from '../highlight.js';

/**
 * The highlighter is the one place in this project doing string-to-HTML work, so the tests
 * concentrate on the two ways that goes wrong: unescaped input, and tokens being matched inside
 * other tokens.
 */
describe('languageFor', () => {
    it.each([
        ['force-app/main/default/classes/ConsentService.cls', 'apex'],
        ['force-app/main/default/triggers/ConsentPreferenceTrigger.trigger', 'apex'],
        ['force-app/main/default/lwc/contactConsentList/contactConsentList.js', 'javascript'],
        ['force-app/main/default/lwc/contactConsentList/contactConsentList.html', 'markup'],
        ['force-app/main/default/pages/ConsentCertificate.page', 'markup'],
        ['force-app/main/default/flows/Consent_Unsubscribe_Request.flow-meta.xml', 'markup'],
        ['lwc.config.json', 'json'],
        ['styles.css', 'css']
    ])('maps %s to %s', (path, expected) => {
        expect(languageFor(path)).toBe(expected);
    });
});

describe('highlight', () => {
    it('escapes HTML in the source so code can never inject markup', () => {
        const output = highlight('String s = a < b && c > d;', 'apex');
        expect(output).toContain('&lt;');
        expect(output).toContain('&gt;');
        expect(output).toContain('&amp;');
        expect(output).not.toContain('<script');
    });

    it('escapes an embedded script tag rather than emitting it', () => {
        const output = highlight('// <script>alert(1)</script>', 'javascript');
        expect(output).not.toMatch(/<script>/);
        expect(output).toContain('&lt;script&gt;');
    });

    it('does not tokenise keywords that appear inside a string', () => {
        const output = highlight("String message = 'return this public';", 'apex');
        // The whole literal is one string token; a naive multi-pass highlighter would wrap
        // 'return' and 'public' inside it and produce nested, broken markup.
        expect(output).toContain('<span class="tok-string">');
        const stringSpan = output.match(/<span class="tok-string">([^<]*)<\/span>/);
        expect(stringSpan[1]).toBe("'return this public'");
    });

    it('does not tokenise keywords that appear inside a comment', () => {
        const output = highlight('// public static void placeholder', 'apex');
        const commentSpan = output.match(/<span class="tok-comment">([^<]*)<\/span>/);
        expect(commentSpan).not.toBeNull();
        expect(commentSpan[1]).toBe('// public static void placeholder');
    });

    it('marks Apex annotations distinctly from keywords', () => {
        const output = highlight('@AuraEnabled(cacheable=true)\npublic static void run() {}', 'apex');
        expect(output).toContain('<span class="tok-annotation">@AuraEnabled</span>');
        expect(output).toContain('<span class="tok-keyword">public</span>');
    });

    it('treats capitalised words as types', () => {
        const output = highlight('List<Contact> contacts = new List<Contact>();', 'apex');
        expect(output).toContain('<span class="tok-type">List</span>');
        expect(output).toContain('<span class="tok-type">Contact</span>');
    });

    it('highlights markup tags and attribute values separately', () => {
        const output = highlight('<lightning-card title="Consent" icon-name="standard:contact"></lightning-card>', 'markup');
        expect(output).toContain('<span class="tok-tag">lightning-card</span>');
        expect(output).toContain('<span class="tok-attr">title</span>');
        // Quotes are left literal: the value sits in text position, where only < > and & are
        // structurally significant. Those three are escaped, which the escaping tests cover.
        expect(output).toContain('<span class="tok-string">"Consent"</span>');
    });

    it('leaves markup comments as a single comment token', () => {
        const output = highlight('<!-- a public comment -->', 'markup');
        expect(output).toContain('<span class="tok-comment">');
        expect(output).not.toContain('tok-tag');
    });

    it('round-trips content: stripping tags returns the original text', () => {
        const source = "public class Foo {\n    // note < > &\n    String s = 'x';\n}";
        const stripped = highlight(source, 'apex')
            .replace(/<[^>]+>/g, '')
            .replace(/&lt;/g, '<')
            .replace(/&gt;/g, '>')
            .replace(/&amp;/g, '&');
        // Nothing may be dropped or duplicated by tokenisation.
        expect(stripped).toBe(source);
    });

    it('handles an empty file without throwing', () => {
        expect(highlight('', 'apex')).toBe('');
    });
});
