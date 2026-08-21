/**
 * Minimal syntax highlighter for Apex, JavaScript, HTML/XML and JSON.
 *
 * Hand-rolled rather than pulled from a library for two reasons: no highlighter ships an Apex
 * grammar worth having, and a dependency here would add far more weight to the bundle than the
 * feature deserves.
 *
 * The whole file is tokenised in ONE regex pass. Highlighting by running a series of
 * replacements is the obvious approach and it is always wrong — the second pass happily matches
 * inside the markup the first pass just inserted, so a keyword inside a string comment gets
 * double-wrapped and the output falls apart.
 */

const APEX_KEYWORDS = [
    'abstract', 'and', 'as', 'break', 'catch', 'class', 'continue', 'delete', 'do', 'else',
    'enum', 'extends', 'final', 'finally', 'for', 'get', 'global', 'if', 'implements', 'insert',
    'instanceof', 'interface', 'merge', 'new', 'not', 'null', 'on', 'or', 'override', 'private',
    'protected', 'public', 'return', 'set', 'static', 'super', 'switch', 'system', 'testmethod',
    'this', 'throw', 'transient', 'try', 'undelete', 'update', 'upsert', 'virtual', 'void',
    'when', 'where', 'while', 'with', 'without', 'sharing', 'select', 'from', 'limit', 'order',
    'by', 'group', 'having', 'find', 'returning', 'true', 'false'
];

const JS_KEYWORDS = [
    'async', 'await', 'break', 'case', 'catch', 'class', 'const', 'continue', 'default',
    'delete', 'do', 'else', 'export', 'extends', 'finally', 'for', 'from', 'function', 'get',
    'if', 'import', 'in', 'instanceof', 'let', 'new', 'of', 'return', 'set', 'static', 'super',
    'switch', 'this', 'throw', 'try', 'typeof', 'var', 'void', 'while', 'yield', 'true',
    'false', 'null', 'undefined'
];

const APEX_TYPES = [
    'Blob', 'Boolean', 'Date', 'Datetime', 'Decimal', 'Double', 'Id', 'Integer', 'List', 'Long',
    'Map', 'Object', 'Set', 'SObject', 'String', 'Time', 'Database', 'Test', 'Assert', 'JSON',
    'Http', 'HttpRequest', 'HttpResponse', 'Limits', 'UserInfo', 'Pattern', 'Schema', 'Type'
];

function escapeHtml(text) {
    return text
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;');
}

function span(className, text) {
    return `<span class="tok-${className}">${escapeHtml(text)}</span>`;
}

export function languageFor(path) {
    if (/\.(cls|trigger|apex)$/i.test(path)) return 'apex';
    if (/\.(js|mjs)$/i.test(path)) return 'javascript';
    if (/\.(html|page|cmp)$/i.test(path)) return 'markup';
    if (/\.(xml|flow-meta\.xml)$/i.test(path)) return 'markup';
    if (/\.json$/i.test(path)) return 'json';
    if (/\.css$/i.test(path)) return 'css';
    return 'plain';
}

/** Highlights source text and returns an HTML string. */
export function highlight(source, language) {
    if (language === 'markup') {
        return highlightMarkup(source);
    }
    return highlightCode(source, language);
}

function highlightCode(source, language) {
    const keywords = new Set(language === 'apex' ? APEX_KEYWORDS : JS_KEYWORDS);
    const types = new Set(language === 'apex' ? APEX_TYPES : []);

    // Order matters: comments and strings must be claimed before anything can match inside them.
    const pattern = /(\/\*[\s\S]*?\*\/|\/\/[^\n]*)|('(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"|`(?:\\.|[^`\\])*`)|(@[A-Za-z_][\w]*)|(\b\d+(?:\.\d+)?\b)|(\b[A-Za-z_][\w]*\b)/g;

    let output = '';
    let lastIndex = 0;
    let match;

    while ((match = pattern.exec(source)) !== null) {
        output += escapeHtml(source.slice(lastIndex, match.index));
        lastIndex = pattern.lastIndex;

        const [text, comment, string, annotation, number, word] = match;
        if (comment) {
            output += span('comment', comment);
        } else if (string) {
            output += span('string', string);
        } else if (annotation) {
            output += span('annotation', annotation);
        } else if (number) {
            output += span('number', number);
        } else if (word) {
            const lower = word.toLowerCase();
            if (keywords.has(language === 'apex' ? lower : word)) {
                output += span('keyword', word);
            } else if (types.has(word)) {
                output += span('type', word);
            } else if (/^[A-Z]/.test(word)) {
                output += span('type', word);
            } else {
                output += escapeHtml(word);
            }
        } else {
            output += escapeHtml(text);
        }
    }
    output += escapeHtml(source.slice(lastIndex));
    return output;
}

function highlightMarkup(source) {
    const pattern = /(<!--[\s\S]*?-->)|(<\/?)([A-Za-z][\w:.-]*)((?:[^>"']|"[^"]*"|'[^']*')*?)(\/?>)/g;

    let output = '';
    let lastIndex = 0;
    let match;

    while ((match = pattern.exec(source)) !== null) {
        output += escapeHtml(source.slice(lastIndex, match.index));
        lastIndex = pattern.lastIndex;

        const [, comment, open, tagName, attributes, close] = match;
        if (comment) {
            output += span('comment', comment);
            continue;
        }
        output += span('punctuation', open);
        output += span('tag', tagName);
        output += highlightAttributes(attributes || '');
        output += span('punctuation', close);
    }
    output += escapeHtml(source.slice(lastIndex));
    return output;
}

function highlightAttributes(attributes) {
    const pattern = /([A-Za-z_][\w:.-]*)(\s*=\s*)("[^"]*"|'[^']*')?/g;
    let output = '';
    let lastIndex = 0;
    let match;

    while ((match = pattern.exec(attributes)) !== null) {
        output += escapeHtml(attributes.slice(lastIndex, match.index));
        lastIndex = pattern.lastIndex;
        const [, name, equals, value] = match;
        output += span('attr', name);
        output += escapeHtml(equals);
        if (value) {
            output += span('string', value);
        }
    }
    output += escapeHtml(attributes.slice(lastIndex));
    return output;
}
